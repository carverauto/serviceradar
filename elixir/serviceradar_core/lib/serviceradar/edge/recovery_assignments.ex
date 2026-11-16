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
  alias ServiceRadar.Repo

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

  The batch is set-based: whatever its size, one transaction runs at most eight
  statements. It ensures and locks every distinct key (in key-id order), records
  every distinct issuance, reads back the issuances and the locked keys'
  candidates and selected resolutions, then folds the entries in order over that
  state, deciding each exactly as committing it alone would (the same
  `projection/3` and `next_projection/3` the lookup and resolver paths use).
  Every writer of a key's candidates, projection and resolutions holds that key's
  lock, so nothing the fold read can change under it. Only then are the appended
  candidates and the changed projections written. The first error in entry order
  rolls the whole batch back.
  """
  @spec commit_issuance([map()]) :: {:ok, :committed | :conflicting} | {:error, term()}
  def commit_issuance(entries) when is_list(entries) and length(entries) in 1..4096 do
    with {:ok, attrs} <- issuance_attributes(entries) do
      transaction(fn -> commit_batch(attrs) end)
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

  # The S1-S8 statements of a set-based commit. Rows travel as one array per
  # column, so no statement's parameter count depends on the batch size. Rows
  # are matched back to entries by ordinal and `jsonb` equality in SQL, the same
  # equality the single-key reads use.
  @ensure_keys_sql """
  INSERT INTO platform.edge_recovery_assignment_keys (mapping_key)
  SELECT u.mapping_key FROM unnest($1::jsonb[]) WITH ORDINALITY AS u(mapping_key, ord)
  ORDER BY u.ord
  ON CONFLICT (mapping_key) DO NOTHING
  """

  @lock_keys_sql """
  SELECT u.ord, k.id, k.mapping_key, k.generation, k.selection_generation,
         k.selected_issuance_id, k.resolver_epoch
  FROM unnest($1::jsonb[]) WITH ORDINALITY AS u(mapping_key, ord)
  JOIN platform.edge_recovery_assignment_keys k ON k.mapping_key = u.mapping_key
  ORDER BY k.id
  FOR UPDATE OF k
  """

  @record_issuances_sql """
  INSERT INTO platform.edge_recovery_assignment_issuances
    (mapping_key, mapping_value, evidence, evidence_sha256)
  SELECT u.mapping_key, u.mapping_value, u.evidence, u.evidence_sha256
  FROM unnest($1::jsonb[], $2::jsonb[], $3::text[], $4::bytea[])
    WITH ORDINALITY AS u(mapping_key, mapping_value, evidence, evidence_sha256, ord)
  ORDER BY u.ord
  ON CONFLICT (mapping_key, mapping_value) DO NOTHING
  """

  @read_issuances_sql """
  SELECT u.ord, i.id, i.mapping_key, i.mapping_value, i.evidence, i.evidence_sha256
  FROM unnest($1::jsonb[], $2::jsonb[]) WITH ORDINALITY AS u(mapping_key, mapping_value, ord)
  JOIN platform.edge_recovery_assignment_issuances i
    ON i.mapping_key = u.mapping_key AND i.mapping_value = u.mapping_value
  """

  # Evidence is the bulk of every row, so a candidate whose issuance S4 already
  # returned comes back without it ($2 lists those ids).
  @read_candidates_sql """
  SELECT c.key_id, c.issuance_id, i.id, i.mapping_key, i.mapping_value, i.evidence,
         i.evidence_sha256
  FROM platform.edge_recovery_assignment_candidates c
  LEFT JOIN platform.edge_recovery_assignment_issuances i
    ON i.id = c.issuance_id AND NOT (c.issuance_id = ANY($2::uuid[]))
  WHERE c.key_id = ANY($1::uuid[])
  """

  @read_selections_sql """
  SELECT key_id, issuance_id, candidate_generation
  FROM platform.edge_recovery_assignment_resolutions
  WHERE key_id = ANY($1::uuid[]) AND outcome = 'selected'
  """

  @insert_candidates_sql """
  INSERT INTO platform.edge_recovery_assignment_candidates (key_id, issuance_id)
  SELECT u.key_id, u.issuance_id FROM unnest($1::uuid[], $2::uuid[]) AS u(key_id, issuance_id)
  ON CONFLICT (key_id, issuance_id) DO NOTHING
  """

  @project_keys_sql """
  UPDATE platform.edge_recovery_assignment_keys k
  SET generation = u.generation,
      selected_issuance_id = u.selected_issuance_id,
      selection_generation = u.selection_generation,
      updated_at = (now() AT TIME ZONE 'utc')
  FROM unnest($1::uuid[], $2::bigint[], $3::uuid[], $4::bigint[])
    AS u(id, generation, selected_issuance_id, selection_generation)
  WHERE k.id = u.id
  """

  defp commit_batch(attrs) do
    keys = attrs |> Enum.map(& &1.mapping_key) |> Enum.uniq()
    pairs = Enum.uniq_by(attrs, &{&1.mapping_key, &1.mapping_value})

    with {:ok, _} <- sql(@ensure_keys_sql, [keys]),
         {:ok, anchors} <- lock_keys(keys),
         {:ok, _} <- sql(@record_issuances_sql, issuance_columns(pairs)),
         {:ok, issuances} <- read_issuances(pairs),
         key_ids = anchors |> Map.values() |> Enum.map(&dump_uuid(&1.id)),
         {:ok, candidates} <- read_candidates(key_ids, issuances),
         {:ok, selections} <- read_selections(key_ids),
         {:ok, batch} <- fold(attrs, anchors, issuances, candidates, selections),
         :ok <- insert_candidates(Enum.reverse(batch.appended)),
         :ok <- project_keys(batch) do
      {:ok, batch.outcome}
    end
  end

  # Decides every entry in order, as the single-entry commit would, over the state
  # read under the key locks plus this batch's own earlier appends.
  defp fold(attrs, anchors, issuances, candidates, selections) do
    initial = %{
      anchors: anchors,
      candidates: candidates,
      appended: [],
      changed: MapSet.new(),
      outcome: :committed
    }

    Enum.reduce_while(attrs, {:ok, initial}, fn entry, {:ok, batch} ->
      issuance = Map.get(issuances, {entry.mapping_key, entry.mapping_value})
      anchor = Map.fetch!(batch.anchors, entry.mapping_key)
      existing = Map.get(batch.candidates, anchor.id, [])

      with :ok <- verify_issuance(issuance),
           {:ok, decision} <- add_candidate(anchor, issuance, existing, selections) do
        {:cont, {:ok, apply_decision(batch, entry.mapping_key, anchor, issuance, decision)}}
      else
        error -> {:halt, error}
      end
    end)
  end

  defp add_candidate(anchor, issuance, existing, selections) do
    cond do
      length(existing) != anchor.generation ->
        {:error, if(existing == [], do: :missing, else: :corrupt)}

      Enum.any?(existing, &(&1.issuance_id == issuance.id)) ->
        replay_candidate(anchor, issuance, existing, selected_at_generation(selections, anchor))

      true ->
        {:ok, {:append, next_projection(anchor, issuance, existing), existing == []}}
    end
  end

  defp replay_candidate(anchor, issuance, existing, decisions) do
    case projection(anchor, existing, decisions) do
      {kind, value} when kind in [:found, :not_scheduled] ->
        {:ok, {:replay, if(value == issuance.mapping_value, do: :committed, else: :conflicting)}}

      :conflicting ->
        {:ok, {:replay, :conflicting}}

      _ ->
        {:error, :corrupt}
    end
  end

  defp apply_decision(batch, _key, _anchor, _issuance, {:replay, outcome}),
    do: merge_outcome(batch, outcome)

  defp apply_decision(batch, key, anchor, issuance, {:append, projection, first?}) do
    candidate = %Candidate{key_id: anchor.id, issuance_id: issuance.id, issuance: issuance}

    merge_outcome(
      %{
        batch
        | anchors: Map.put(batch.anchors, key, Map.merge(anchor, projection)),
          candidates: Map.update(batch.candidates, anchor.id, [candidate], &(&1 ++ [candidate])),
          appended: [{anchor.id, issuance.id} | batch.appended],
          changed: MapSet.put(batch.changed, key)
      },
      if(first?, do: :committed, else: :conflicting)
    )
  end

  defp merge_outcome(batch, :conflicting), do: %{batch | outcome: :conflicting}
  defp merge_outcome(batch, :committed), do: batch

  # The `selected` resolutions recorded at the key's current (in-memory) generation.
  defp selected_at_generation(selections, anchor) do
    selections
    |> Map.get(anchor.id, [])
    |> Enum.filter(&(&1.candidate_generation == anchor.generation))
  end

  defp lock_keys(keys) do
    with {:ok, %{rows: rows}} <- sql(@lock_keys_sql, [keys]) do
      by_ord = List.to_tuple(keys)

      anchors =
        Map.new(rows, fn [ord, id, mapping_key, generation, selection_generation, selected, epoch] ->
          {elem(by_ord, ord - 1),
           %Key{
             id: load_uuid(id),
             mapping_key: mapping_key,
             generation: generation,
             selection_generation: selection_generation,
             selected_issuance_id: load_uuid(selected),
             resolver_epoch: epoch
           }}
        end)

      if map_size(anchors) == length(keys), do: {:ok, anchors}, else: {:error, :corrupt}
    end
  end

  defp read_issuances(pairs) do
    columns = [Enum.map(pairs, & &1.mapping_key), Enum.map(pairs, & &1.mapping_value)]

    with {:ok, %{rows: rows}} <- sql(@read_issuances_sql, columns) do
      by_ord = List.to_tuple(pairs)

      {:ok,
       Map.new(rows, fn [ord | issuance] ->
         pair = elem(by_ord, ord - 1)
         {{pair.mapping_key, pair.mapping_value}, issuance_row(issuance)}
       end)}
    end
  end

  defp read_candidates(key_ids, issuances) do
    known = issuances |> Map.values() |> Map.new(&{&1.id, &1})
    known_ids = known |> Map.keys() |> Enum.map(&dump_uuid/1)

    with {:ok, %{rows: rows}} <- sql(@read_candidates_sql, [key_ids, known_ids]) do
      {:ok,
       Enum.group_by(
         rows,
         fn [key_id | _] -> load_uuid(key_id) end,
         fn [key_id, issuance_id | issuance] ->
           issuance_id = load_uuid(issuance_id)

           %Candidate{
             key_id: load_uuid(key_id),
             issuance_id: issuance_id,
             issuance: issuance_row(issuance) || Map.get(known, issuance_id)
           }
         end
       )}
    end
  end

  defp read_selections(key_ids) do
    with {:ok, %{rows: rows}} <- sql(@read_selections_sql, [key_ids]) do
      {:ok,
       Enum.group_by(
         rows,
         fn [key_id | _] -> load_uuid(key_id) end,
         fn [_key_id, issuance_id, generation] ->
           %{
             outcome: :selected,
             issuance_id: load_uuid(issuance_id),
             candidate_generation: generation
           }
         end
       )}
    end
  end

  defp insert_candidates([]), do: :ok

  defp insert_candidates(appended) do
    columns = [
      Enum.map(appended, fn {key_id, _} -> dump_uuid(key_id) end),
      Enum.map(appended, fn {_, issuance_id} -> dump_uuid(issuance_id) end)
    ]

    with {:ok, _} <- sql(@insert_candidates_sql, columns), do: :ok
  end

  defp project_keys(%{changed: changed} = batch) do
    if MapSet.size(changed) == 0 do
      :ok
    else
      anchors = Enum.map(changed, &Map.fetch!(batch.anchors, &1))

      columns = [
        Enum.map(anchors, &dump_uuid(&1.id)),
        Enum.map(anchors, & &1.generation),
        Enum.map(anchors, &dump_uuid(&1.selected_issuance_id)),
        Enum.map(anchors, & &1.selection_generation)
      ]

      with {:ok, _} <- sql(@project_keys_sql, columns), do: :ok
    end
  end

  defp issuance_columns(pairs) do
    [
      Enum.map(pairs, & &1.mapping_key),
      Enum.map(pairs, & &1.mapping_value),
      Enum.map(pairs, & &1.evidence),
      Enum.map(pairs, & &1.evidence_sha256)
    ]
  end

  defp issuance_row([nil | _]), do: nil

  defp issuance_row([id, mapping_key, mapping_value, evidence, evidence_sha256]) do
    %Issuance{
      id: load_uuid(id),
      mapping_key: mapping_key,
      mapping_value: mapping_value,
      evidence: evidence,
      evidence_sha256: evidence_sha256
    }
  end

  defp sql(statement, params), do: Repo.query(statement, params)

  defp load_uuid(nil), do: nil
  defp load_uuid(raw), do: Ecto.UUID.load!(raw)

  defp dump_uuid(nil), do: nil
  defp dump_uuid(id), do: Ecto.UUID.dump!(id)

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
