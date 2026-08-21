defmodule ServiceRadar.Inventory.Identity.Fence do
  @moduledoc """
  Compare-and-set on a device's identity revision.

  A consumer that resolves a device once and writes later has, until now, had no
  way to discover that its identity decision went stale in between. This is the
  write half of that fence: pin the revision `Resolver.resolve_device_identity/2`
  returned, re-check it at write time, and refuse the write if a merge, unmerge,
  split, alias invalidation or identifier reassignment moved it.

  ## Why the policy is retry-once-then-abandon

  Neither of the obvious alternatives works here.

  **Raising** is wrong because the highest-volume consumers are batch pipelines --
  metric, sweep and inventory ingest -- where one raised device fails a whole
  batch of unrelated devices.

  **Silently dropping** is wrong because several consumers are state machines.
  `Alert`, `AnomalyEpisode` and `DeviceCompositeCheckResult` all have transitions
  that, if dropped, leave a record open forever with nothing left to close it.

  So a stale pin re-resolves and retries **once**, and a second observed
  transition inside one write abandons with telemetry. Two identity transitions
  during a single write is a merge storm -- a different bug, and not one to paper
  over by retrying until it stops.

  ## Deliberately not automatic

  Nothing pins implicitly. A fence that silently wrapped every write would read as
  a guarantee everywhere while only actually holding where someone had threaded a
  revision through, which is worse than no fence. Call sites opt in.
  """

  alias ServiceRadar.Inventory.Identity.Resolver

  require Ash.Expr
  require Logger

  @telemetry_prefix [:serviceradar, :identity_fence]

  @typedoc "A device id paired with the identity revision observed when it was resolved."
  @type pinned :: {String.t(), integer()}

  @doc """
  Add the compare-and-set predicate to a **pending** changeset.

  On the pending caller changeset, not inside an action-level `change filter(...)`:
  Ash rebuilds atomic updates from a second changeset, so a filter registered in
  the action does not survive to constrain the update that actually runs.

  The loser of the race gets `Ash.Error.Changes.StaleRecord`, which `stale?/1`
  recognises.
  """
  @spec pin(Ash.Changeset.t(), integer()) :: Ash.Changeset.t()
  def pin(changeset, revision) when is_integer(revision) do
    Ash.Changeset.filter(changeset, Ash.Expr.expr(identity_revision == ^revision))
  end

  @doc """
  True when a failure is a superseded pin rather than a real error.

  Matches the shape Ash returns for a filtered update that matched no row, the
  same way `agent_gateway_sync.ex` and `action_token.ex` already do it.
  """
  @spec stale?(term()) :: boolean()
  def stale?(%Ash.Error.Changes.StaleRecord{}), do: true
  def stale?(%{errors: errors}) when is_list(errors), do: Enum.any?(errors, &stale?/1)
  def stale?(errors) when is_list(errors), do: Enum.any?(errors, &stale?/1)
  def stale?(_), do: false

  @doc """
  Resolve a device, run `fun` with the pinned identity, and re-resolve once if the
  pin was superseded.

  `fun` receives `{device_id, identity_revision}` and should apply the pin with
  `pin/2` on whatever changeset it builds. It returns any `{:ok, _}` on success or
  `{:error, reason}` on failure; only a stale-pin failure is retried, everything
  else is returned untouched.

  Options are those of `Resolver.resolve_device_identity/2`, plus `:pipeline` --
  a short atom naming the caller, carried in telemetry so an operator can tell
  which pipeline is losing races.
  """
  @spec with_pinned_identity(map(), keyword(), (pinned() -> {:ok, term()} | {:error, term()})) ::
          {:ok, term()} | {:error, term()}
  def with_pinned_identity(update, opts, fun) when is_function(fun, 1) do
    pipeline = Keyword.get(opts, :pipeline, :unknown)

    case attempt(update, opts, fun) do
      {:stale, pinned} ->
        emit(:stale, pipeline, pinned)

        # One retry, against a freshly resolved identity.
        case attempt(update, opts, fun) do
          {:stale, second} ->
            emit(:abandoned, pipeline, second)

            Logger.warning(
              "identity fence: abandoning write for #{elem(second, 0)} after two identity " <>
                "transitions during one write (pipeline=#{pipeline})"
            )

            {:error, :identity_fence_stale}

          other ->
            other
        end

      other ->
        other
    end
  end

  defp attempt(update, opts, fun) do
    case Resolver.resolve_device_identity(update, opts) do
      {:ok, pinned} ->
        case fun.(pinned) do
          {:error, reason} = error ->
            if stale?(reason), do: {:stale, pinned}, else: error

          other ->
            other
        end

      {:error, _} = error ->
        error
    end
  end

  defp emit(event, pipeline, {device_id, revision}) do
    :telemetry.execute(
      @telemetry_prefix ++ [event],
      %{count: 1},
      %{pipeline: pipeline, device_id: device_id, pinned_revision: revision}
    )
  end
end
