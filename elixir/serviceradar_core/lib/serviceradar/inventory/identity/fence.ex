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

  ## Batch enforcement

  `pin_batch/1` and `fenced_write/3` are the enforcing form for batch writers
  (`SyncIngestor`). A batch pins every device it resolved -- its revision, or that
  no row exists yet -- and then writes inside one transaction that first locks
  those device rows (`FOR UPDATE`, in uid order) and re-reads them. An identity
  transition bumps the revision of the rows it touches, so any merge, unmerge,
  delete, restore or reassignment that committed since the pin shows up as a
  moved revision, and one that has not committed yet waits for the batch to
  commit. A pin whose device moved, vanished (a purge) or appeared already
  transitioned is stale: its write is withheld, and the caller re-resolves it and
  retries once, then abandons it (`abandon/2`) with telemetry.
  """

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Inventory.Identity.Resolver

  require Ash.Expr
  require Ash.Query
  require Logger

  @telemetry_prefix [:serviceradar, :identity_fence]

  # Page size for the streamed batch pin read. Bounded on purpose: the stream
  # opts out of Ash's max_page_size clamp, so this is the only thing keeping a
  # large ingestion batch from being requested as one page.
  @pin_read_batch_size 250

  @typedoc "A device id paired with the identity revision observed when it was resolved."
  @type pinned :: {String.t(), integer()}

  @typedoc """
  What a batch pinned for one device: the revision it saw, `:absent` when no row
  existed yet (the write will create it), or `:merged` when resolution already
  raced a merge (the row is a merged-away tombstone, so the decision is stale).
  """
  @type batch_pin :: integer() | :absent | :merged

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
  Pin a batch: read the identity state of every resolved device id at once.

  Tombstones are read too. A non-merged tombstone is pinned by revision like a
  live row (a write may legitimately revive it); a merged-away one is `:merged`,
  because the resolver never lands on it except when a merge raced the
  resolution. Unlike the observe-only reads this raises on failure: an
  enforcing fence that cannot read must not let the batch through unchecked.
  """
  @spec pin_batch([String.t()]) :: %{String.t() => batch_pin()}
  def pin_batch(device_ids) when is_list(device_ids) do
    ids = device_ids |> Enum.filter(&(is_binary(&1) and &1 != "")) |> Enum.uniq()
    rows = read_identity_rows(ids, lock?: false)

    Map.new(ids, fn id ->
      case Map.get(rows, id) do
        nil -> {id, :absent}
        %{deleted_at: %_{}, deleted_reason: "merged"} -> {id, :merged}
        %{identity_revision: revision} -> {id, revision}
      end
    end)
  end

  @doc """
  Run a batch write under the fence.

  Inside one transaction: lock the pinned device rows, compute which pins went
  stale, emit `[:serviceradar, :identity_fence, :stale]` for each, and call
  `fun` with the set of stale device ids. `fun` must write only the devices NOT
  in that set, and return `{:ok, value}` or `{:error, reason}` (which rolls the
  whole write back). Returns `{:ok, {value, stale_ids}}`.

  The locks are what make this enforcement rather than detection: a transition
  that has not committed when the rows are locked cannot commit until the write
  has, and one that has committed is seen as a moved revision.
  """
  @spec fenced_write(
          %{String.t() => batch_pin()},
          atom(),
          (MapSet.t() -> {:ok, term()} | {:error, term()})
        ) :: {:ok, {term(), MapSet.t()}} | {:error, term()}
  def fenced_write(pins, pipeline, fun) when is_map(pins) and is_function(fun, 1) do
    Ash.transact([Device], fn ->
      current = read_identity_rows(Map.keys(pins), lock?: true)
      stale = stale_ids(pins, current)

      Enum.each(stale, fn device_id ->
        emit_batch(:stale, pipeline, device_id, Map.fetch!(pins, device_id), current)
      end)

      case fun.(stale) do
        {:ok, value} -> {value, stale}
        {:error, _} = error -> error
      end
    end)
  end

  @doc """
  Give up on writes whose pins went stale twice, and say so: one
  `[:serviceradar, :identity_fence, :abandoned]` event per device and one log
  line. Never silent, never raised.
  """
  @spec abandon(%{String.t() => batch_pin()}, atom()) :: :ok
  def abandon(pins, _pipeline) when map_size(pins) == 0, do: :ok

  def abandon(pins, pipeline) when is_map(pins) do
    Enum.each(pins, fn {device_id, pin} ->
      emit_batch(:abandoned, pipeline, device_id, pin, %{})
    end)

    Logger.warning(
      "identity fence: abandoned #{map_size(pins)} write(s) after two identity " <>
        "transitions during the write (pipeline=#{pipeline}): " <>
        Enum.join(Enum.sort(Map.keys(pins)), ", ")
    )

    :ok
  end

  @doc """
  Report one stale pin found outside `fenced_write/3` (a single-device consumer
  that re-resolves on its own): one `[:serviceradar, :identity_fence, :stale]`
  event, with the pin it held and what it found (a revision, `:absent` or `:merged`).
  """
  @spec report_stale(atom(), String.t(), batch_pin(), batch_pin()) :: :ok
  def report_stale(pipeline, device_id, pin, current) do
    current_row =
      if is_integer(current), do: %{device_id => %{identity_revision: current}}, else: %{}

    emit_batch(:stale, pipeline, device_id, pin, current_row)
  end

  @doc false
  # The stale set for a batch's pins against the rows now locked. Public for the
  # unit tests of the decision table.
  @spec stale_ids(%{String.t() => batch_pin()}, %{String.t() => map()}) :: MapSet.t()
  def stale_ids(pins, current) do
    pins
    |> Enum.filter(fn {device_id, pin} -> stale_pin?(pin, Map.get(current, device_id)) end)
    |> MapSet.new(&elem(&1, 0))
  end

  # A resolution that already landed on a merged-away tombstone.
  defp stale_pin?(:merged, _row), do: true
  # Still no row: the write creates it.
  defp stale_pin?(:absent, nil), do: false
  # Another writer created the row since the pin, and nothing has happened to it.
  defp stale_pin?(:absent, %{deleted_at: nil, identity_revision: 1}), do: false
  # Created and already transitioned (merged, deleted, reassigned) since the pin.
  defp stale_pin?(:absent, _row), do: true
  # Purged since the pin: writing would re-create it.
  defp stale_pin?(revision, nil) when is_integer(revision), do: true
  defp stale_pin?(revision, %{identity_revision: revision}), do: false
  defp stale_pin?(revision, _row) when is_integer(revision), do: true

  defp read_identity_rows([], _opts), do: %{}

  defp read_identity_rows(ids, opts) do
    actor = actor()

    query =
      Device
      |> Ash.Query.for_read(:read, %{include_deleted: true}, actor: actor)
      |> Ash.Query.filter(uid in ^ids)
      |> Ash.Query.select([:uid, :identity_revision, :deleted_at, :deleted_reason])
      |> Ash.Query.sort(uid: :asc)

    query =
      if Keyword.get(opts, :lock?, false), do: Ash.Query.lock(query, :for_update), else: query

    query
    |> Ash.stream!(actor: actor, batch_size: @pin_read_batch_size)
    |> Map.new(&{&1.uid, &1})
  end

  defp emit_batch(event, pipeline, device_id, pin, current) do
    current_revision =
      case Map.get(current, device_id) do
        %{identity_revision: revision} -> revision
        _ -> nil
      end

    :telemetry.execute(
      @telemetry_prefix ++ [event],
      %{count: 1},
      %{
        pipeline: pipeline,
        device_id: device_id,
        pinned_revision: if(is_integer(pin), do: pin),
        pin: pin,
        current_revision: current_revision
      }
    )
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
    # This streams, and sizing a page to the batch does NOT work as a substitute.
    # Ash clamps any requested page down to the action's `max_page_size` with a
    # silent `Enum.min/1`, so `page: [limit: length(ids)]` was capped no matter how
    # large the batch was -- and Ash computes `more?` against the *requested* limit
    # rather than the clamped one, so the short page reported itself complete.
    # Every uid past the cap was absent from this map and therefore read as
    # unpinned: precisely the "clean batch" this function must never fabricate.
    # Callers pass whole ingestion batches, so the cap was reached routinely.
    actor = actor()

    Device
    |> Ash.Query.for_read(:read, %{include_deleted: false}, actor: actor)
    |> Ash.Query.filter(uid in ^ids)
    |> Ash.Query.select([:uid, :identity_revision])
    |> Ash.stream!(actor: actor, batch_size: @pin_read_batch_size)
    |> Map.new(&{&1.uid, &1.identity_revision})
  rescue
    # Observe-only must never break the caller. A failed read still must not be
    # reported as "nothing drifted", which is why this returns an empty map and
    # inert/2 logs rather than yielding a map the caller would trust.
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
