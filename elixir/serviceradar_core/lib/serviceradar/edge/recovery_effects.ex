defmodule ServiceRadar.Edge.RecoveryEffects do
  @moduledoc """
  Applies recovery loss effects in the caller's operation transaction and lock.

  The caller owns authenticated receipt, exact received-byte bounds, terminal copy
  validation and completion. `:applied` means the audit, partial range coverage,
  generation fences and retry intents required by every span have been written;
  only the caller's successful commit can make that result acknowledgeable.
  `:pending` and `:blocked` must retain the broker delivery without a terminal ACK.

  Lookup transitions are append-only first occurrences of a finite outcome set,
  not one row per retry. Span identity contains no body or comparison digest.
  """

  alias ServiceRadar.Edge.RecoveryAssignment
  alias ServiceRadar.Edge.RecoveryAssignments
  alias ServiceRadar.Edge.RecoveryEffect
  alias ServiceRadar.Edge.RecoveryGenerationFence, as: Fence
  alias ServiceRadar.Edge.RecoveryLossSpan, as: Span
  alias ServiceRadar.Edge.RecoveryLossTransition, as: Transition
  alias ServiceRadar.Edge.RecoveryRangeLoss, as: RangeLoss
  alias ServiceRadar.Edge.RecoveryRetryIntent, as: RetryIntent
  alias ServiceRadar.Edge.RecoveryValidate
  alias Serviceradar.Edge.V1.EdgeClassificationSpanV1
  alias Serviceradar.Edge.V1.SpoolLossTombstoneV1
  alias ServiceRadar.Repo

  require Ash.Query

  @scheduled_sweep Serviceradar.Edge.V1.EdgeSourceAuthorizationKind.value(
                     :EDGE_SOURCE_AUTHORIZATION_KIND_SCHEDULED_SWEEP
                   )

  @resources [Span, Transition, RangeLoss, Fence, RetryIntent]

  @doc "Resources to include in the operation owner's transaction."
  def resources, do: @resources

  @doc "Apply the already received manifest under its registration lock, in the caller's transaction."
  def apply_manifest(scope, agent, %SpoolLossTombstoneV1{} = tombstone, pages) do
    with true <- Repo.in_transaction?(),
         {:ok, namespace} <- namespace(scope, agent),
         :ok <- RecoveryValidate.tombstone(tombstone, pages) do
      context =
        Map.merge(namespace, %{
          recovery_id: Ecto.UUID.cast!(tombstone.recovery_id),
          prior_spool_id: Ecto.UUID.cast!(tombstone.prior_spool_id)
        })

      pages
      |> Enum.flat_map(fn page ->
        Enum.with_index(page.classification_spans, fn span, index ->
          {page.page_index, index, span}
        end)
      end)
      |> Enum.reduce_while({:ok, :applied}, fn {page, index, span}, {:ok, state} ->
        case apply_span(context, page, index, span) do
          {:ok, next} -> {:cont, {:ok, combined(state, next)}}
          error -> {:halt, error}
        end
      end)
    else
      false -> {:error, :transaction_required}
      error -> error
    end
  end

  def apply_manifest(_, _, _, _), do: {:error, :recovery_identity}

  @doc "An exact generation lookup; backend errors are never an unfenced answer."
  def generation_fenced?(scope, agent, prior_spool_id) do
    with {:ok, namespace} <- namespace(scope, agent),
         {:ok, prior} <- Ecto.UUID.cast(prior_spool_id) do
      namespace
      |> fence_query()
      |> Ash.Query.filter(prior_spool_id == ^prior)
      |> Ash.exists(actor: actor())
    else
      :error -> {:error, :recovery_identity}
      error -> error
    end
  end

  @doc "A bounded complete fence list; overflow returns an error, never a truncated authorization snapshot."
  def generation_fences(scope, agent, limit \\ 256)

  def generation_fences(scope, agent, limit) when is_integer(limit) and limit in 1..4096 do
    with {:ok, namespace} <- namespace(scope, agent),
         {:ok, fences} <-
           namespace |> fence_query() |> Ash.Query.limit(limit + 1) |> Ash.read(actor: actor()) do
      if length(fences) > limit,
        do: {:error, :fence_snapshot_limit},
        else: {:ok, Enum.map(fences, &Ecto.UUID.dump!(&1.prior_spool_id))}
    end
  end

  def generation_fences(_, _, _), do: {:error, :fence_snapshot_limit}

  defp apply_span(context, page_index, span_index, span) do
    attrs =
      Map.merge(context, %{
        page_index: page_index,
        span_index: span_index,
        span: span |> EdgeClassificationSpanV1.encode() |> IO.iodata_to_binary()
      })

    with {:ok, _} <- create(Span, :record, attrs),
         {:ok, stored} <-
           attrs |> span_query() |> Ash.Query.lock(:for_update) |> Ash.read_one(actor: actor()) do
      cond do
        stored.span != attrs.span or stored.prior_spool_id != attrs.prior_spool_id ->
          quarantine(stored, :body_conflict)

        stored.outcome in [:body_conflict, :range_conflict] ->
          {:ok, :blocked}

        stored.state == :applied ->
          replay_effect(stored, span)

        true ->
          lookup_effect(stored, span)
      end
    end
  end

  defp lookup_effect(stored, %{classification: {kind, _}} = span) do
    lookup =
      if kind == :unattributable,
        do: :not_looked_up,
        else:
          RecoveryAssignments.lookup(
            Ecto.UUID.dump!(stored.network_scope_id),
            stored.agent_id,
            span
          )

    with {:ok, effect} <- RecoveryEffect.classify(kind, lookup) do
      apply_effect(stored, span, effect)
    end
  end

  defp replay_effect(stored, %{classification: {kind, _}} = span) do
    lookup =
      if kind == :unattributable,
        do: :not_looked_up,
        else: {stored.outcome, stored.mapping_value}

    with {:ok, transition} <-
           stored.id |> transition_query(stored.outcome) |> Ash.read_one(actor: actor()),
         true <- not is_nil(transition) and transition.mapping_value == stored.mapping_value,
         {:ok, effect} <- RecoveryEffect.classify(kind, lookup) do
      apply_effect(stored, span, effect)
    else
      false -> quarantine(stored, :corrupt)
      error -> error
    end
  end

  defp apply_effect(stored, span, effect) do
    with {:ok, mapping_key} <- mapping_key(stored, span, effect),
         {:ok, :same} <- record_transition(stored, effect.outcome, effect.mapping_value),
         {:ok, _} <- maybe_fence(stored, effect),
         {:ok, :same} <- maybe_range(stored, mapping_key, effect),
         {:ok, :same} <- maybe_retry(stored, mapping_key, effect),
         {:ok, _} <- update_span(stored, effect.state, effect.outcome, effect.mapping_value) do
      {:ok, effect.state}
    else
      {:ok, :conflict} -> quarantine(stored, :range_conflict)
      {:error, :invalid_value} -> quarantine(stored, :corrupt)
      error -> error
    end
  end

  defp mapping_key(_stored, _span, %{mapping_value: nil}), do: {:ok, nil}

  defp mapping_key(stored, span, %{mapping_value: value}) do
    with {:ok, key} <-
           RecoveryAssignment.key(Ecto.UUID.dump!(stored.network_scope_id), stored.agent_id, span),
         :ok <- RecoveryAssignment.validate_value(key, value),
         do: {:ok, key}
  end

  defp maybe_fence(stored, %{fence?: true}),
    do: create(Fence, :fence, Map.take(stored, [:network_scope_id, :agent_id, :prior_spool_id]))

  defp maybe_fence(_, _), do: {:ok, :not_required}

  defp maybe_range(stored, key, %{range?: true, mapping_value: value}) do
    with {:ok, _} <-
           create(RangeLoss, :record, %{
             span_id: stored.id,
             mapping_key: key,
             mapping_value: value
           }),
         {:ok, row} <-
           RangeLoss |> Ash.Query.filter(span_id == ^stored.id) |> Ash.read_one(actor: actor()) do
      if row.mapping_key == key, do: compare_value(row, value), else: {:ok, :conflict}
    end
  end

  defp maybe_range(_, _, _), do: {:ok, :same}

  defp maybe_retry(stored, key, %{retry?: true, mapping_value: value}) do
    intent_key =
      if is_nil(key),
        do: %{"kind" => "generation", "prior_spool_id" => stored.prior_spool_id},
        else: %{"kind" => "range", "mapping_key" => key}

    attrs =
      stored
      |> Map.take([:network_scope_id, :agent_id, :recovery_id])
      |> Map.merge(%{
        intent_key: intent_key,
        mapping_value: value,
        scheduler: retry_scheduler(key)
      })

    with {:ok, _} <- create(RetryIntent, :enqueue, attrs),
         {:ok, row} <-
           RetryIntent
           |> Ash.Query.filter(
             network_scope_id == ^attrs.network_scope_id and agent_id == ^attrs.agent_id
           )
           |> Ash.Query.filter(recovery_id == ^attrs.recovery_id and intent_key == ^intent_key)
           |> Ash.read_one(actor: actor()) do
      if row.scheduler == attrs.scheduler, do: compare_value(row, value), else: {:ok, :conflict}
    end
  end

  defp maybe_retry(_, _, _), do: {:ok, :same}

  # The existing lease reconciler owns generation repair and scheduled sweeps.
  # Other source families must retain their intent for their own semantic owner.
  defp retry_scheduler(nil), do: :sweep

  defp retry_scheduler(%{
         "span_identity" => [_, _, _, _, _, _, _, [@scheduled_sweep, _, _, _] | _]
       }), do: :sweep

  defp retry_scheduler(_), do: :unassigned

  defp record_transition(stored, outcome, value) do
    with {:ok, _} <-
           create(Transition, :record, %{
             span_id: stored.id,
             outcome: outcome,
             mapping_value: value
           }),
         {:ok, row} <- stored.id |> transition_query(outcome) |> Ash.read_one(actor: actor()) do
      compare_value(row, value)
    end
  end

  defp quarantine(stored, outcome) do
    with {:ok, _} <- record_transition(stored, outcome, nil),
         {:ok, _} <- update_span(stored, :blocked, outcome, nil),
         do: {:ok, :blocked}
  end

  defp compare_value(%{mapping_value: expected}, value) when expected == value, do: {:ok, :same}
  defp compare_value(_, _), do: {:ok, :conflict}

  defp update_span(stored, state, outcome, value),
    do:
      stored
      |> Ash.Changeset.for_update(:apply, %{state: state, outcome: outcome, mapping_value: value},
        actor: actor()
      )
      |> Ash.update()

  defp span_query(attrs) do
    Span
    |> Ash.Query.filter(
      network_scope_id == ^attrs.network_scope_id and agent_id == ^attrs.agent_id
    )
    |> Ash.Query.filter(
      recovery_id == ^attrs.recovery_id and page_index == ^attrs.page_index and
        span_index == ^attrs.span_index
    )
  end

  defp transition_query(span_id, outcome),
    do: Ash.Query.filter(Transition, span_id == ^span_id and outcome == ^outcome)

  defp fence_query(namespace),
    do:
      Ash.Query.filter(
        Fence,
        network_scope_id == ^namespace.network_scope_id and agent_id == ^namespace.agent_id
      )

  defp namespace(scope, agent) when is_binary(agent) and byte_size(agent) in 1..256 do
    with {:ok, scope} <- Ecto.UUID.cast(scope),
         true <- String.valid?(agent) and not String.contains?(agent, <<0>>) do
      {:ok, %{network_scope_id: scope, agent_id: agent}}
    else
      _ -> {:error, :recovery_identity}
    end
  end

  defp namespace(_, _), do: {:error, :recovery_identity}

  defp combined(:blocked, _), do: :blocked
  defp combined(_, :blocked), do: :blocked
  defp combined(:pending, _), do: :pending
  defp combined(_, :pending), do: :pending
  defp combined(:applied, :applied), do: :applied

  defp create(resource, action, attrs),
    do: resource |> Ash.Changeset.for_create(action, attrs, actor: actor()) |> Ash.create()

  defp actor, do: ServiceRadar.Actors.SystemActor.system(:recovery_effects)
end
