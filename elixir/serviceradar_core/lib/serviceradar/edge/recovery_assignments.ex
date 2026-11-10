defmodule ServiceRadar.Edge.RecoveryAssignments do
  @moduledoc """
  Durable historical assignment mappings. Issuers commit original evidence and its
  candidate before delivering collection authority. Recovery consumers only read
  this store; they own generation fences, quarantine and terminal acknowledgments.

  A differing candidate never overwrites an earlier value. Resolution selects one
  for the current candidate generation, under a separately acquired resolver epoch.
  Both candidates and all rejected resolution attempts remain available for audit.

  No time-based collector or destroy action exists. Retention is conservative until
  a safety proof covering recovery, redrive and lifecycle retention has an owner.
  """

  alias ServiceRadar.Edge.RecoveryAssignment
  alias ServiceRadar.Edge.RecoveryAssignmentCandidate, as: Candidate
  alias ServiceRadar.Edge.RecoveryAssignmentEvidence
  alias ServiceRadar.Edge.RecoveryAssignmentIssuance, as: Issuance
  alias ServiceRadar.Edge.RecoveryAssignmentKey, as: Key
  alias ServiceRadar.Edge.RecoveryAssignmentResolution, as: Resolution
  alias ServiceRadar.Edge.RecoveryTransaction

  require Ash.Query

  @resources [Key, Issuance, Candidate, Resolution]

  @doc "Returns one of the six historical lookup outcomes for an authenticated namespace."
  @spec lookup(binary(), String.t(), term()) :: RecoveryAssignment.lookup()
  def lookup(scope, agent, span) do
    with {:ok, key} <- RecoveryAssignment.key(scope, agent, span),
         {:ok, result} <- transaction(fn -> lookup_key(key) end) do
      result
    else
      {:error, :invalid_key} -> :corrupt
      {:error, _} -> :temporarily_unavailable
    end
  end

  @doc """
  Issuer-only commit boundary. Each entry contains `key`, `value` and original
  `proof`; callers must construct it from authority they are about to deliver,
  never from a recovery request or a current-state reconstruction.

  Same-value replay keeps the first issuance evidence. A new differing value is
  retained as a conflict and returned as such; the caller must withhold delivery.
  """
  @spec commit_issuance([map()]) :: {:ok, :committed | :conflicting} | {:error, term()}
  def commit_issuance(entries) when is_list(entries) and length(entries) in 1..4096 do
    with {:ok, attrs} <- issuance_attributes(entries) do
      transaction(fn ->
        Enum.reduce_while(attrs, {:ok, :committed}, fn entry, {:ok, outcome} ->
          with {:ok, anchor} <- ensure_key(entry.mapping_key),
               {:ok, issuance} <- record_issuance(entry),
               :ok <- verify_issuance(issuance),
               {:ok, current} <- add_candidate(anchor, issuance) do
            {:cont, {:ok, if(current == :conflicting, do: :conflicting, else: outcome)}}
          else
            error -> {:halt, error}
          end
        end)
      end)
    end
  end

  def commit_issuance(_), do: {:error, :invalid_issuance}

  @doc "Repairs candidate membership only from independently retained original issuance evidence."
  @spec repair(Ecto.UUID.t()) :: {:ok, :committed | :conflicting} | {:error, term()}
  def repair(issuance_id) do
    transaction(fn ->
      with {:ok, issuance} when not is_nil(issuance) <-
             Issuance |> Ash.Query.filter(id == ^issuance_id) |> Ash.read_one(actor: actor()),
           :ok <- verify_issuance(issuance),
           {:ok, anchor} <- ensure_key(issuance.mapping_key) do
        restore_candidates(anchor)
      else
        {:ok, nil} -> {:error, :missing_original_issuance}
        error -> error
      end
    end)
  end

  @doc "Fences previous resolvers and returns the immutable candidate IDs of this generation."
  @spec acquire_resolver(map()) :: {:ok, map()} | {:error, term()}
  def acquire_resolver(key) do
    transaction(fn ->
      with {:ok, anchor} when not is_nil(anchor) <- locked_key(key),
           {:ok, candidates} <- candidates(anchor),
           {:ok, updated} <- project(anchor, %{resolver_epoch: anchor.resolver_epoch + 1}) do
        {:ok,
         %{
           resolver_epoch: updated.resolver_epoch,
           candidate_generation: updated.generation,
           issuance_ids: Enum.map(candidates, & &1.issuance_id)
         }}
      else
        {:ok, nil} -> {:error, :missing}
        error -> error
      end
    end)
  end

  @doc "Selects a retained candidate with an exact resolver fence and candidate generation."
  @spec resolve(map(), non_neg_integer(), non_neg_integer(), Ecto.UUID.t()) ::
          {:ok, :selected | atom()} | {:error, term()}
  def resolve(key, epoch, generation, issuance_id)
      when is_integer(epoch) and epoch >= 0 and is_integer(generation) and generation >= 0 do
    transaction(fn ->
      with {:ok, anchor} when not is_nil(anchor) <- locked_key(key),
           {:ok, candidates} <- candidates(anchor),
           {:ok, decisions} <- decisions(anchor) do
        outcome =
          resolution_outcome(anchor, candidates, decisions, epoch, generation, issuance_id)

        with {:ok, _} <- record_resolution(anchor, epoch, generation, issuance_id, outcome),
             {:ok, _} <- apply_selection(anchor, issuance_id, outcome) do
          {:ok, outcome}
        end
      else
        {:ok, nil} -> {:error, :missing}
        error -> error
      end
    end)
  end

  def resolve(_, _, _, _), do: {:error, :invalid_resolution}

  defp lookup_key(key) do
    with {:ok, anchor} when not is_nil(anchor) <- locked_key(key),
         {:ok, candidates} <- candidates(anchor),
         {:ok, decisions} <- decisions(anchor) do
      {:ok, projection(anchor, candidates, decisions)}
    else
      {:ok, nil} -> {:ok, :missing}
      error -> error
    end
  end

  defp projection(_anchor, [], _decisions), do: :missing

  defp projection(anchor, candidates, decisions) do
    selected = selected_ids(decisions)

    cond do
      Enum.any?(candidates, &(verify_issuance(&1.issuance) != :ok)) -> :corrupt
      Enum.any?(candidates, &(&1.issuance.mapping_key != anchor.mapping_key)) -> :corrupt
      length(candidates) != anchor.generation -> :corrupt
      length(selected) > 1 -> :conflicting
      length(candidates) > 1 and selected == [] -> :conflicting
      anchor.selection_generation != anchor.generation -> :corrupt
      selected != [] and selected != [anchor.selected_issuance_id] -> :corrupt
      true -> selected_value(anchor, candidates)
    end
  end

  defp selected_value(anchor, candidates) do
    case Enum.find(candidates, &(&1.issuance_id == anchor.selected_issuance_id)) do
      nil ->
        :corrupt

      candidate ->
        RecoveryAssignment.selected(anchor.mapping_key, candidate.issuance.mapping_value)
    end
  end

  defp resolution_outcome(anchor, candidates, decisions, epoch, generation, issuance_id) do
    selected = selected_ids(decisions)

    cond do
      epoch < anchor.resolver_epoch -> :stale_resolver
      epoch > anchor.resolver_epoch or epoch == 0 -> :future_resolver
      generation != anchor.generation -> :changed_candidates
      not Enum.any?(candidates, &(&1.issuance_id == issuance_id)) -> :unknown_candidate
      Enum.any?(candidates, &(verify_issuance(&1.issuance) != :ok)) -> :corrupt
      length(candidates) != anchor.generation -> :corrupt
      length(selected) > 1 -> :conflicting
      selected != [] and selected != [issuance_id] -> :selection_conflict
      true -> :selected
    end
  end

  defp record_resolution(anchor, epoch, generation, issuance_id, outcome) do
    create(Resolution, :record, %{
      key_id: anchor.id,
      issuance_id: issuance_id,
      resolver_epoch: epoch,
      candidate_generation: generation,
      outcome: outcome
    })
  end

  defp apply_selection(anchor, issuance_id, :selected),
    do:
      project(anchor, %{
        selected_issuance_id: issuance_id,
        selection_generation: anchor.generation
      })

  defp apply_selection(anchor, _, _), do: {:ok, anchor}

  defp selected_ids(decisions) do
    decisions
    |> Enum.filter(&(&1.outcome == :selected))
    |> Enum.map(& &1.issuance_id)
    |> Enum.uniq()
  end

  defp add_candidate(anchor, issuance) do
    with {:ok, existing} <- candidates(anchor) do
      cond do
        length(existing) != anchor.generation ->
          {:error, if(existing == [], do: :missing, else: :corrupt)}

        Enum.any?(existing, &(&1.issuance_id == issuance.id)) ->
          replay_candidate(anchor, issuance, existing)

        true ->
          append_candidate(anchor, issuance, existing)
      end
    end
  end

  defp replay_candidate(anchor, issuance, existing) do
    with {:ok, decisions} <- decisions(anchor) do
      case projection(anchor, existing, decisions) do
        {kind, value} when kind in [:found, :not_scheduled] ->
          {:ok, if(value == issuance.mapping_value, do: :committed, else: :conflicting)}

        :conflicting ->
          {:ok, :conflicting}

        _ ->
          {:error, :corrupt}
      end
    end
  end

  defp append_candidate(anchor, issuance, existing) do
    with {:ok, _} <- create(Candidate, :record, %{key_id: anchor.id, issuance_id: issuance.id}),
         {:ok, _} <- project(anchor, next_projection(anchor, issuance, existing)) do
      {:ok, if(existing == [], do: :committed, else: :conflicting)}
    end
  end

  defp restore_candidates(anchor) do
    with {:ok, originals} <-
           Issuance
           |> Ash.Query.filter(mapping_key == ^anchor.mapping_key)
           |> Ash.read(actor: actor()),
         :ok <- restore_originals(anchor, originals),
         {:ok, anchor} <- restored_projection(anchor, originals),
         {:ok, candidates} <- candidates(anchor),
         {:ok, decisions} <- decisions(anchor) do
      case projection(anchor, candidates, decisions) do
        {kind, _} when kind in [:found, :not_scheduled] -> {:ok, :committed}
        :conflicting -> {:ok, :conflicting}
        _ -> {:error, :corrupt}
      end
    end
  end

  defp restore_originals(anchor, originals) do
    Enum.reduce_while(originals, :ok, fn original, :ok ->
      with :ok <- verify_issuance(original),
           {:ok, _} <- create(Candidate, :record, %{key_id: anchor.id, issuance_id: original.id}) do
        {:cont, :ok}
      else
        error -> {:halt, error}
      end
    end)
  end

  defp restored_projection(%{generation: 0} = anchor, [original]),
    do:
      project(anchor, %{generation: 1, selected_issuance_id: original.id, selection_generation: 1})

  defp restored_projection(%{generation: 0} = anchor, originals),
    do: project(anchor, %{generation: length(originals)})

  defp restored_projection(anchor, _), do: {:ok, anchor}

  defp next_projection(anchor, issuance, existing) do
    generation = anchor.generation + 1

    if existing == [] and anchor.generation == 0 do
      %{
        generation: generation,
        selected_issuance_id: issuance.id,
        selection_generation: generation
      }
    else
      %{generation: generation, selected_issuance_id: nil, selection_generation: nil}
    end
  end

  defp ensure_key(key) do
    with {:ok, _} <- create(Key, :ensure, %{mapping_key: key}), do: locked_key(key)
  end

  defp record_issuance(entry) do
    with {:ok, _} <- create(Issuance, :record, entry) do
      Issuance
      |> Ash.Query.filter(
        mapping_key == ^entry.mapping_key and mapping_value == ^entry.mapping_value
      )
      |> Ash.read_one(actor: actor())
    end
  end

  defp locked_key(key) do
    Key
    |> Ash.Query.filter(mapping_key == ^key)
    |> Ash.Query.lock(:for_update)
    |> Ash.read_one(actor: actor())
  end

  defp candidates(anchor) do
    Candidate
    |> Ash.Query.filter(key_id == ^anchor.id)
    |> Ash.Query.load(:issuance)
    |> Ash.read(actor: actor())
  end

  defp decisions(anchor) do
    Resolution
    |> Ash.Query.filter(key_id == ^anchor.id and candidate_generation == ^anchor.generation)
    |> Ash.read(actor: actor())
  end

  defp project(anchor, attrs) do
    anchor |> Ash.Changeset.for_update(:project, attrs, actor: actor()) |> Ash.update()
  end

  defp issuance_attributes(entries) do
    entries
    |> Enum.reduce_while({:ok, []}, fn
      %{key: key, value: value, proof: proof}, {:ok, attrs} when is_map(proof) ->
        with :ok <- RecoveryAssignment.validate_value(key, value),
             :ok <- RecoveryAssignmentEvidence.validate(key, value, proof),
             {:ok, evidence} <- Jason.encode(%{"key" => key, "value" => value, "proof" => proof}),
             true <- byte_size(evidence) <= 32_768 do
          entry = %{
            mapping_key: key,
            mapping_value: value,
            evidence: evidence,
            evidence_sha256: :crypto.hash(:sha256, evidence)
          }

          {:cont, {:ok, [entry | attrs]}}
        else
          _ -> {:halt, {:error, :invalid_issuance}}
        end

      _, _ ->
        {:halt, {:error, :invalid_issuance}}
    end)
    |> case do
      {:ok, attrs} -> {:ok, Enum.reverse(attrs)}
      error -> error
    end
  end

  defp verify_issuance(%Issuance{} = issuance) do
    with true <- is_binary(issuance.evidence) and byte_size(issuance.evidence) <= 32_768,
         true <- :crypto.hash(:sha256, issuance.evidence) == issuance.evidence_sha256,
         {:ok, %{"key" => key, "value" => value, "proof" => proof} = decoded} <-
           Jason.decode(issuance.evidence),
         true <- map_size(decoded) == 3 and is_map(proof),
         true <- key == issuance.mapping_key and value == issuance.mapping_value,
         :ok <- RecoveryAssignment.validate_value(key, value),
         :ok <- RecoveryAssignmentEvidence.validate(key, value, proof) do
      :ok
    else
      _ -> {:error, :corrupt}
    end
  end

  defp verify_issuance(_), do: {:error, :corrupt}

  defp create(resource, action, attrs),
    do: resource |> Ash.Changeset.for_create(action, attrs, actor: actor()) |> Ash.create()

  defp actor, do: ServiceRadar.Actors.SystemActor.system(:recovery_assignments)

  defp transaction(fun), do: RecoveryTransaction.run(@resources, fun)
end
