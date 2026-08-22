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

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Inventory.Identity.Resolver

  require Ash.Expr
  require Ash.Query
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

  @doc """
  Snapshot a device's identity revision so a later `observe/2` can say whether it
  moved. Observe-only: nothing is filtered and no write is constrained.

  Returns `:error` when the device cannot be read, which `observe/2` accepts, so a
  caller can pin unconditionally without a branch.
  """
  @spec observe_pin(String.t()) :: {:ok, pinned()} | :error
  def observe_pin(device_id) when is_binary(device_id) do
    case current_revision(device_id) do
      {:ok, revision} -> {:ok, {device_id, revision}}
      :missing -> :error
    end
  rescue
    exception -> inert(exception, :error)
  end

  def observe_pin(_device_id), do: :error

  @doc """
  Snapshot many devices in one read.

  `enqueue_many/1` in the composite-check refresh path runs inside sweep result
  ingestion and can carry thousands of uids, so the per-device form would add a
  query each. Returns a map of uid to revision, omitting anything unreadable.
  """
  @spec observe_pins([String.t()]) :: %{String.t() => integer()}
  def observe_pins([]), do: %{}

  def observe_pins(device_ids) when is_list(device_ids) do
    ids = Enum.filter(device_ids, &(is_binary(&1) and &1 != ""))

    # Two details here are load-bearing, both of which fail silently if dropped.
    #
    # `for_read/3` supplies the :read action's `include_deleted` argument. The
    # action filters on `is_nil(deleted_at) or ^arg(:include_deleted)`, so
    # without it the argument is nil, the OR evaluates to NULL, and the query
    # matches nothing.
    #
    # The explicit page limit is sized to the batch. Device's read declares
    # `pagination keyset?: true, default_limit: 5000` and does not allow
    # `page: false` ("Pagination is required"), so the default would cap a sweep
    # batch at 5000 uids and silently report the rest as unpinned.
    actor = actor()

    Device
    |> Ash.Query.for_read(:read, %{include_deleted: false}, actor: actor)
    |> Ash.Query.filter(uid in ^ids)
    |> Ash.Query.select([:uid, :identity_revision])
    |> Ash.read(actor: actor, page: [limit: max(length(ids), 1)])
    |> case do
      {:ok, %{results: devices}} ->
        Map.new(devices, &{&1.uid, &1.identity_revision})

      {:ok, devices} when is_list(devices) ->
        Map.new(devices, &{&1.uid, &1.identity_revision})

      {:error, reason} ->
        # Observe-only must never break the caller, but it also must not report a
        # failed read as "nothing drifted" -- that reads as a clean batch.
        Logger.warning("identity fence: batch pin read failed: #{inspect(reason)}")
        %{}
    end
  rescue
    exception -> inert(exception, %{})
  end

  @doc """
  Report whether a pin is still current. **Never blocks and never fails.**

  This is the observe-only half of the rollout: it measures how often each
  pipeline would have lost a race, so enforcement can be turned on per pipeline
  against evidence rather than a guess. Callers must not branch on the result --
  it is always `:ok`.

  A device that has been merged away reads as missing here, because the merge
  soft-deletes the source and the default read filters it. That is reported as
  `:observed_missing` rather than folded into drift, since the two want different
  responses: drift means re-resolve, missing means the pin's device no longer
  exists at all.
  """
  @spec observe({:ok, pinned()} | pinned() | :error, atom()) :: :ok
  def observe(:error, _pipeline), do: :ok

  def observe({:ok, {device_id, revision}}, pipeline),
    do: observe({device_id, revision}, pipeline)

  def observe({device_id, pinned_revision}, pipeline)
      when is_binary(device_id) and is_integer(pinned_revision) do
    observed = current_revision(device_id)
    report(pipeline, device_id, pinned_revision, observed)

    case observed do
      {:ok, current} when current != pinned_revision ->
        Logger.info(
          "identity fence (observe-only): #{device_id} moved " <>
            "#{pinned_revision} -> #{current} during a write (pipeline=#{pipeline})"
        )

      _ ->
        :ok
    end

    :ok
  rescue
    exception -> inert(exception, :ok)
  end

  def observe(_pinned, _pipeline), do: :ok

  @doc """
  Compare a whole batch of pins in one read.

  The batch ingest pipelines resolve hundreds of devices and then run a handful of
  bulk writes, so the per-device `observe/2` would add a query each. This re-reads
  every pinned uid once and reports per device, logging a single summary rather
  than a line per device.
  """
  @spec observe_many(%{String.t() => integer()}, atom()) :: :ok
  def observe_many(pins, _pipeline) when map_size(pins) == 0, do: :ok

  def observe_many(pins, pipeline) when is_map(pins) do
    current = observe_pins(Map.keys(pins))

    drifted =
      Enum.count(pins, fn {device_id, pinned_revision} ->
        observed =
          case Map.fetch(current, device_id) do
            {:ok, revision} -> {:ok, revision}
            :error -> :missing
          end

        report(pipeline, device_id, pinned_revision, observed)
        observed != {:ok, pinned_revision}
      end)

    if drifted > 0 do
      Logger.info(
        "identity fence (observe-only): #{drifted} of #{map_size(pins)} pinned devices " <>
          "moved during a batch write (pipeline=#{pipeline})"
      )
    end

    :ok
  rescue
    exception -> inert(exception, :ok)
  end

  # The observe-only contract is "never blocks and never fails", and that has to
  # hold against a raise, not just an {:error, _}. It is not defensive padding:
  # several call sites sit inside a function-level `rescue` that logs and moves on
  # -- ProcessorSweep.update_device_availability_only/1 and Refresh.enqueue_many/1
  # both do. A pin that raised there would be swallowed by the caller's own rescue
  # and take the real work with it: the three availability writes, or every
  # composite-check enqueue in the batch. Measurement must not be able to do that.
  defp inert(exception, fallback) do
    Logger.warning("identity fence: observation failed: #{Exception.message(exception)}")
    fallback
  end

  defp report(pipeline, device_id, pinned_revision, {:ok, pinned_revision}) do
    emit(:observed_fresh, pipeline, {device_id, pinned_revision}, %{
      current_revision: pinned_revision
    })
  end

  defp report(pipeline, device_id, pinned_revision, {:ok, current}) do
    emit(:observed_drift, pipeline, {device_id, pinned_revision}, %{current_revision: current})
  end

  defp report(pipeline, device_id, pinned_revision, :missing) do
    emit(:observed_missing, pipeline, {device_id, pinned_revision}, %{current_revision: nil})
  end

  defp current_revision(device_id) do
    case Ash.get(Device, device_id, actor: actor()) do
      {:ok, %Device{identity_revision: revision}} when is_integer(revision) -> {:ok, revision}
      _ -> :missing
    end
  end

  # Policies stay enforced for the fence's own reads, and the reads are
  # attributable in an audit log rather than anonymous.
  defp actor, do: SystemActor.system(:identity_fence)

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

  defp emit(event, pipeline, pinned), do: emit(event, pipeline, pinned, %{})

  defp emit(event, pipeline, {device_id, revision}, extra) when is_map(extra) do
    :telemetry.execute(
      @telemetry_prefix ++ [event],
      %{count: 1},
      Map.merge(
        %{pipeline: pipeline, device_id: device_id, pinned_revision: revision},
        extra
      )
    )
  end
end
