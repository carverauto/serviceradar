defmodule ServiceRadar.Inventory.Availability.Resolution do
  @moduledoc """
  Transactional availability resolution (`add-merged-device-availability`, design
  Decision 1, steps 3 and 4).

  For each batch of at most 500 devices, in one transaction:

  1. The device rows are locked `FOR NO KEY UPDATE` in uid order, the order every device
     writer locks in. Tombstoned devices are neither locked nor resolved.
  2. Their per-agent ledger rows, evidence and vantage expectations are read under that
     lock, so a write that committed before the lock is seen.
  3. `ServiceRadar.Inventory.Availability.Resolver.resolve/3` decides each device.
  4. Stage b: the decision is written to `device_availability_shadow`, only for a
     device whose state, provenance, conflict flag or agent counters differ from the
     stored row. Nothing on `ocsf_devices` is written.

  Resolution never reads, locks or waits on the invalidation log. The only rows it
  locks are device rows (uid order) and then their shadow rows, which no other writer
  touches, so it adds no lock-order edge beyond the device-row order the legacy status
  writers already use.

  Only `shadow` writes. `resolve_devices/1` is the inline entry point for write paths;
  in `legacy` it returns before issuing any query (`Mode.cached/0`).
  """

  import Ecto.Query

  alias ServiceRadar.Inventory.Availability.AuthorityClass
  alias ServiceRadar.Inventory.Availability.Mode
  alias ServiceRadar.Inventory.Availability.Resolver
  alias ServiceRadar.Repo

  require Logger

  @batch_size 500

  @lock_devices """
  SELECT d.uid, d.availability_source_agent_id, d.availability_state, d.availability_changed_at,
         s.device_uid IS NOT NULL, s.availability_state, s.decided_by, s.conflict, s.agents,
         s.changed_at, clock_timestamp() AT TIME ZONE 'utc'
  FROM platform.ocsf_devices AS d
  LEFT JOIN platform.device_availability_shadow AS s ON s.device_uid = d.uid
  WHERE d.uid = ANY($1::text[]) AND d.deleted_at IS NULL
  ORDER BY d.uid
  FOR NO KEY UPDATE OF d
  """

  @ledger """
  SELECT a.device_uid, a.agent_id, a.is_available, a.checked_at, a.consecutive_down,
         a.sweep_group_id::text, a.metadata ->> 'sweep_reporter_expectation',
         extract(epoch FROM platform.availability_ledger_ttl(a.sweep_group_id))::bigint
  FROM platform.device_agent_availability AS a
  WHERE a.device_uid = ANY($1::text[])
  """

  @evidence """
  SELECT device_uid, source_kind, source_instance, reporter_agent_id, authority_class, state,
         observed_at, expires_at, confirmations, reporter_eligible
  FROM platform.device_availability_evidence
  WHERE device_uid = ANY($1::text[])
  """

  @expectations """
  SELECT device_uid, agent_id, bool_or(expectation = 'blocked')
  FROM platform.device_vantage_expectations
  WHERE device_uid = ANY($1::text[])
  GROUP BY device_uid, agent_id
  """

  @type result :: %{resolved: non_neg_integer(), written: non_neg_integer()}

  @doc "Devices per resolution transaction."
  @spec batch_size() :: pos_integer()
  def batch_size, do: @batch_size

  @doc """
  Resolves `device_uids` for a write path, inline. Never fails the caller's write.

  In `legacy` (per `Mode.cached/0`) it returns `{:ok, :legacy}` without a query. Otherwise
  each batch runs in its own transaction, or inside the caller's transaction when there
  is one, with every statement in a savepoint. A failure is logged and the devices are
  appended to the invalidation log, so the resolver worker resolves them later.
  """
  @spec resolve_devices([String.t()]) :: {:ok, result() | :legacy} | {:error, term()}
  def resolve_devices(device_uids) do
    if Mode.resolving?() do
      device_uids |> normalize_uids() |> resolve_inline()
    else
      {:ok, :legacy}
    end
  end

  defp resolve_inline([]), do: {:ok, %{resolved: 0, written: 0}}

  defp resolve_inline(uids) do
    if Repo.in_transaction?() do
      {:ok, resolve_locked(uids, mode: :savepoint)}
    else
      uids
      |> Enum.chunk_every(@batch_size)
      |> Enum.reduce({:ok, %{resolved: 0, written: 0}}, fn batch, {:ok, acc} ->
        {:ok, result} = Repo.transaction(fn -> resolve_locked(batch) end)
        {:ok, add(acc, result)}
      end)
    end
  rescue
    error ->
      Logger.warning(
        "availability resolution failed; deferring #{length(uids)} device(s) to the resolver " <>
          "worker: #{Exception.message(error)}"
      )

      defer(uids)
      {:error, error}
  end

  @doc """
  Resolves `device_uids` inside the current transaction (the caller opened it), in
  batches of at most #{@batch_size} in uid order. Raises on failure, so the caller's
  transaction rolls back; used by the resolver worker, the expiry job and the full pass.

  The mode is read inside the transaction: anything but `shadow` resolves nothing.
  """
  @spec resolve_locked([String.t()], keyword()) :: result()
  def resolve_locked(device_uids, query_opts \\ []) do
    uids = normalize_uids(device_uids)

    if uids != [] and Mode.current(query_opts) == :shadow do
      uids
      |> Enum.chunk_every(@batch_size)
      |> Enum.reduce(%{resolved: 0, written: 0}, &add(&2, resolve_batch(&1, query_opts)))
    else
      %{resolved: 0, written: 0}
    end
  end

  @doc """
  Locks the live device rows of `device_uids` in uid order (`FOR NO KEY UPDATE`), as the
  resolution does, and returns the uids it locked. A writer that will resolve after
  writing other rows of these devices takes this first, so it locks in the same order as
  everything else: device, then the device's own rows.
  """
  @spec lock_devices([String.t()], keyword()) :: MapSet.t(String.t())
  def lock_devices(device_uids, query_opts \\ []) do
    case normalize_uids(device_uids) do
      [] ->
        MapSet.new()

      uids ->
        %{rows: rows} =
          Repo.query!(
            """
            SELECT uid FROM platform.ocsf_devices
            WHERE uid = ANY($1::text[]) AND deleted_at IS NULL
            ORDER BY uid FOR NO KEY UPDATE
            """,
            [uids],
            query_opts
          )

        MapSet.new(rows, &hd/1)
    end
  end

  @doc """
  Appends `device_uids` to the invalidation log with a plain INSERT, so the resolver
  worker resolves them. Used when an inline resolution could not run.
  """
  @spec defer([String.t()]) :: :ok
  def defer(device_uids) do
    case normalize_uids(device_uids) do
      [] ->
        :ok

      uids ->
        opts = if Repo.in_transaction?(), do: [mode: :savepoint], else: []

        Repo.query!(
          "INSERT INTO platform.availability_invalidations (device_uid) SELECT unnest($1::text[])",
          [uids],
          opts
        )

        :ok
    end
  rescue
    error ->
      Logger.error("availability invalidation append failed: #{Exception.message(error)}")
      :ok
  end

  defp resolve_batch(uids, query_opts) do
    %{rows: device_rows} = Repo.query!(@lock_devices, [uids], query_opts)

    case device_rows do
      [] ->
        %{resolved: 0, written: 0}

      rows ->
        locked = Enum.map(rows, &hd/1)
        now = rows |> Enum.map(&List.last/1) |> Enum.max(NaiveDateTime) |> to_datetime()
        inputs = load_inputs(locked, query_opts)

        changed =
          Enum.flat_map(rows, fn row ->
            {device, stored} = device_and_stored(row)
            decision = Resolver.resolve(device, Map.get(inputs, device.uid, empty_inputs()), now)
            if changed?(stored, decision), do: [{device.uid, decision}], else: []
          end)

        write(changed, now, query_opts)

        :telemetry.execute(
          [:serviceradar, :availability, :resolution],
          %{resolved: length(rows), written: length(changed)},
          %{}
        )

        %{resolved: length(rows), written: length(changed)}
    end
  end

  defp device_and_stored([
         uid,
         pin,
         mirror_state,
         mirror_changed_at,
         shadowed?,
         state,
         decided_by,
         conflict,
         agents,
         changed_at,
         _now
       ]) do
    stored =
      if shadowed? do
        %{state: state_atom(state), decided_by: decided_by, conflict: conflict, agents: agents}
      end

    # Before the first shadow decision, the previous state is what the device shows: the
    # legacy mirror. That is also the previous state the resolver will see at cutover.
    previous =
      if shadowed? do
        %{state: state_atom(state), decided_by: decided_by, changed_at: to_datetime(changed_at)}
      else
        %{
          state: state_atom(mirror_state),
          decided_by: nil,
          changed_at: to_datetime(mirror_changed_at)
        }
      end

    {%{uid: uid, pin: pin, previous: previous}, stored}
  end

  defp changed?(nil, _decision), do: true

  defp changed?(stored, decision) do
    stored.state != decision.state or stored.decided_by != decision.decided_by or
      stored.conflict != decision.conflict or stored.agents != decision.agents
  end

  defp load_inputs(uids, query_opts) do
    %{rows: ledger} = Repo.query!(@ledger, [uids], query_opts)
    %{rows: evidence} = Repo.query!(@evidence, [uids], query_opts)
    %{rows: expectations} = Repo.query!(@expectations, [uids], query_opts)

    by_device = fn rows, build -> Enum.group_by(rows, &hd/1, build) end

    ledger = by_device.(ledger, &ledger_row/1)
    evidence = by_device.(evidence, &evidence_row/1)

    expectations =
      expectations
      |> by_device.(fn [_uid, agent_id, blocked?] ->
        {agent_id, if(blocked?, do: :blocked, else: :reachable)}
      end)
      |> Map.new(fn {uid, pairs} -> {uid, Map.new(pairs)} end)

    Map.new(uids, fn uid ->
      {uid,
       %{
         ledger: Map.get(ledger, uid, []),
         evidence: Map.get(evidence, uid, []),
         expectations: Map.get(expectations, uid, %{})
       }}
    end)
  end

  defp empty_inputs, do: %{ledger: [], evidence: [], expectations: %{}}

  defp ledger_row([
         _uid,
         agent_id,
         available?,
         checked_at,
         consecutive_down,
         sweep_group_id,
         expectation,
         ttl
       ]) do
    %{
      agent_id: agent_id,
      available?: available?,
      checked_at: to_datetime(checked_at),
      consecutive_down: consecutive_down,
      sweep_group_id: sweep_group_id,
      reporter_expectation: expectation,
      ttl_seconds: ttl
    }
  end

  defp evidence_row([
         _uid,
         kind,
         instance,
         reporter,
         class,
         state,
         observed_at,
         expires_at,
         confirmations,
         eligible?
       ]) do
    {:ok, class} = AuthorityClass.cast(class)

    %{
      source_kind: kind,
      source_instance: instance,
      reporter_agent_id: reporter,
      authority_class: class,
      state: if(state == "up", do: :up, else: :down),
      observed_at: to_datetime(observed_at),
      expires_at: to_datetime(expires_at),
      confirmations: confirmations,
      reporter_eligible: eligible?
    }
  end

  defp write([], _now, _query_opts), do: :ok

  defp write(changed, now, query_opts) do
    computed_at = to_naive(now)

    rows =
      changed
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map(fn {uid, decision} ->
        %{
          device_uid: uid,
          availability_state: Atom.to_string(decision.state),
          decided_by: decision.decided_by,
          conflict: decision.conflict,
          agents: decision.agents,
          changed_at: to_naive(decision.changed_at),
          computed_at: computed_at
        }
      end)

    replace =
      from(s in "device_availability_shadow",
        update: [
          set: [
            availability_state: fragment("EXCLUDED.availability_state"),
            decided_by: fragment("EXCLUDED.decided_by"),
            conflict: fragment("EXCLUDED.conflict"),
            agents: fragment("EXCLUDED.agents"),
            changed_at: fragment("EXCLUDED.changed_at"),
            computed_at: fragment("EXCLUDED.computed_at")
          ]
        ]
      )

    Repo.insert_all(
      "device_availability_shadow",
      rows,
      [prefix: "platform", on_conflict: replace, conflict_target: [:device_uid]] ++ query_opts
    )

    :ok
  end

  defp normalize_uids(uids) do
    uids
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp add(acc, result),
    do: %{resolved: acc.resolved + result.resolved, written: acc.written + result.written}

  defp state_atom("available"), do: :available
  defp state_atom("unavailable"), do: :unavailable
  defp state_atom(_state), do: :unknown

  defp to_datetime(nil), do: nil
  defp to_datetime(%DateTime{} = at), do: at

  defp to_datetime(%NaiveDateTime{} = at) do
    at |> DateTime.from_naive!("Etc/UTC") |> microsecond_precision()
  end

  defp to_naive(nil), do: nil
  defp to_naive(%DateTime{} = at), do: DateTime.to_naive(at)

  defp microsecond_precision(%DateTime{microsecond: {microsecond, _}} = at),
    do: %{at | microsecond: {microsecond, 6}}
end
