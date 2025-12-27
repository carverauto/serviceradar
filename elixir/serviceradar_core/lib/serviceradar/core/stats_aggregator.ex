defmodule ServiceRadar.Core.StatsAggregator do
  @moduledoc """
  Device statistics aggregator that maintains periodic snapshots.

  Port of Go core's stats_aggregator.go. Computes and caches device statistics
  including totals, availability, activity, and capability breakdowns.

  ## Features

  - Periodic refresh (default: 10 seconds)
  - Active device window (default: 24 hours)
  - Per-partition statistics
  - Capability tracking (ICMP, SNMP, Sysmon)
  - Canonical record filtering
  - CNPG reconciliation
  - Alert handler integration

  ## Usage

      # Start the aggregator (usually in supervision tree)
      StatsAggregator.start_link(interval: :timer.seconds(10))

      # Get current snapshot
      snapshot = StatsAggregator.snapshot()

      # Get metadata
      meta = StatsAggregator.meta()
  """

  use GenServer

  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Monitoring.AlertGenerator

  require Logger

  @default_interval :timer.seconds(10)
  @default_active_window :timer.hours(24)
  @default_tracked_capabilities ~w(icmp snmp sysmon)
  @default_partition "default"
  # Reserved for future CNPG reconciliation
  # @drift_tolerance_pct 1
  # @drift_min_difference 100

  # Snapshot type
  defmodule Snapshot do
    @moduledoc "Device statistics snapshot"
    defstruct [
      :timestamp,
      total_devices: 0,
      available_devices: 0,
      unavailable_devices: 0,
      active_devices: 0,
      devices_with_collectors: 0,
      devices_with_icmp: 0,
      devices_with_snmp: 0,
      devices_with_sysmon: 0,
      partitions: []
    ]
  end

  defmodule PartitionStats do
    @moduledoc "Per-partition statistics"
    defstruct [
      :partition_id,
      device_count: 0,
      available_count: 0,
      active_count: 0
    ]
  end

  defmodule Meta do
    @moduledoc "Aggregation metadata for diagnostics"
    defstruct raw_records: 0,
              processed_records: 0,
              skipped_nil_records: 0,
              skipped_tombstoned_records: 0,
              skipped_service_components: 0,
              skipped_non_canonical: 0,
              skipped_sweep_only_records: 0,
              inferred_canonical_fallback: 0
  end

  # GenServer state
  defmodule State do
    @moduledoc false
    defstruct [
      :interval,
      :active_window,
      :tracked_capabilities,
      :alert_handler,
      :timer_ref,
      current: %Snapshot{timestamp: DateTime.utc_now()},
      last_meta: %Meta{},
      last_mismatch_log: nil
    ]
  end

  # Client API

  @doc """
  Start the stats aggregator GenServer.

  ## Options

  - `:interval` - Refresh interval in ms (default: 10s)
  - `:active_window` - Window for "active" devices in ms (default: 24h)
  - `:tracked_capabilities` - List of capability names to track
  - `:alert_handler` - Function to call on anomalies
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Get the current statistics snapshot.
  """
  @spec snapshot() :: Snapshot.t()
  def snapshot do
    GenServer.call(__MODULE__, :snapshot)
  catch
    :exit, {:noproc, _} -> %Snapshot{timestamp: DateTime.utc_now()}
  end

  @doc """
  Get the current metadata.
  """
  @spec meta() :: Meta.t()
  def meta do
    GenServer.call(__MODULE__, :meta)
  catch
    :exit, {:noproc, _} -> %Meta{}
  end

  @doc """
  Force an immediate refresh of the statistics.
  """
  @spec refresh() :: :ok
  def refresh do
    GenServer.cast(__MODULE__, :refresh)
  catch
    :exit, {:noproc, _} -> :ok
  end

  # GenServer Callbacks

  @impl true
  def init(opts) do
    interval = Keyword.get(opts, :interval, @default_interval)
    active_window = Keyword.get(opts, :active_window, @default_active_window)
    tracked_capabilities = Keyword.get(opts, :tracked_capabilities, @default_tracked_capabilities)
    alert_handler = Keyword.get(opts, :alert_handler)

    state = %State{
      interval: interval,
      active_window: active_window,
      tracked_capabilities: tracked_capabilities,
      alert_handler: alert_handler
    }

    # Do initial refresh
    state = do_refresh(state)

    # Schedule periodic refresh
    timer_ref = schedule_refresh(interval)

    Logger.info(
      "StatsAggregator started with interval=#{interval}ms, active_window=#{active_window}ms"
    )

    {:ok, %{state | timer_ref: timer_ref}}
  end

  @impl true
  def handle_call(:snapshot, _from, state) do
    {:reply, clone_snapshot(state.current), state}
  end

  @impl true
  def handle_call(:meta, _from, state) do
    {:reply, state.last_meta, state}
  end

  @impl true
  def handle_cast(:refresh, state) do
    state = do_refresh(state)
    {:noreply, state}
  end

  @impl true
  def handle_info(:refresh, state) do
    state = do_refresh(state)
    timer_ref = schedule_refresh(state.interval)
    {:noreply, %{state | timer_ref: timer_ref}}
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # Private functions

  defp schedule_refresh(interval) do
    Process.send_after(self(), :refresh, interval)
  end

  defp do_refresh(state) do
    {snapshot, meta} = compute_snapshot(state)

    previous = state.current
    previous_meta = state.last_meta

    # Log the refresh
    log_snapshot_refresh(previous, previous_meta, snapshot, meta)

    # Record telemetry
    record_stats_metrics(meta, snapshot)

    # Invoke alert handler
    invoke_alert_handler(state.alert_handler, previous, previous_meta, snapshot, meta)

    %{state | current: snapshot, last_meta: meta}
  end

  defp compute_snapshot(state) do
    now = DateTime.utc_now()
    snapshot = %Snapshot{timestamp: now}
    meta = %Meta{}

    # Query devices from database
    case query_devices() do
      {:ok, devices} ->
        meta = %{meta | raw_records: length(devices)}

        if Enum.empty?(devices) do
          {snapshot, meta}
        else
          # Filter and select canonical records
          {selected, meta} = select_canonical_records(devices, meta)
          meta = %{meta | processed_records: length(selected)}

          if Enum.empty?(selected) do
            {snapshot, meta}
          else
            # Compute statistics
            compute_device_stats(selected, snapshot, meta, state)
          end
        end

      {:error, reason} ->
        Logger.warning("Failed to query devices for stats: #{inspect(reason)}")
        {snapshot, meta}
    end
  end

  defp query_devices do
    # Query all devices - the database is the source of truth
    Device
    |> Ash.read()
  end

  defp select_canonical_records(devices, meta) do
    # Group by canonical ID to deduplicate
    canonical = %{}
    fallback = %{}

    {canonical, fallback, meta} =
      Enum.reduce(devices, {canonical, fallback, meta}, fn device, {can, fall, m} ->
        process_device_record(device, can, fall, m)
      end)

    # Merge fallback records that don't have canonical equivalents
    {canonical, meta} =
      Enum.reduce(fallback, {canonical, meta}, fn {key, device}, {can, m} ->
        if Map.has_key?(can, key) do
          {can, %{m | skipped_non_canonical: m.skipped_non_canonical + 1}}
        else
          {Map.put(can, key, device),
           %{m | inferred_canonical_fallback: m.inferred_canonical_fallback + 1}}
        end
      end)

    selected = Map.values(canonical)
    {selected, meta}
  end

  defp process_device_record(nil, canonical, fallback, meta) do
    {canonical, fallback, %{meta | skipped_nil_records: meta.skipped_nil_records + 1}}
  end

  defp process_device_record(device, canonical, fallback, meta) do
    device_id = String.trim(device.uid || "")
    canonical_id = get_canonical_device_id(device)

    key =
      cond do
        device_id == "" ->
          nil

        is_service_device?(device_id) ->
          device_id

        canonical_id != "" ->
          canonical_id

        true ->
          device_id
      end

    if key == nil or key == "" do
      {canonical, fallback, %{meta | skipped_non_canonical: meta.skipped_non_canonical + 1}}
    else
      normalized_key = String.downcase(key)

      # Check if this is a canonical record (canonical_id matches device_id)
      is_canonical =
        canonical_id != "" and String.downcase(canonical_id) == String.downcase(device_id)

      if is_canonical do
        # Prefer canonical records
        case Map.get(canonical, normalized_key) do
          nil ->
            {Map.put(canonical, normalized_key, device), fallback, meta}

          existing ->
            if should_replace_record?(existing, device) do
              {Map.put(canonical, normalized_key, device), fallback, meta}
            else
              {canonical, fallback,
               %{meta | skipped_non_canonical: meta.skipped_non_canonical + 1}}
            end
        end
      else
        # Non-canonical record - add to fallback
        case Map.get(canonical, normalized_key) do
          nil ->
            # No canonical record, add to fallback
            case Map.get(fallback, normalized_key) do
              nil ->
                {canonical, Map.put(fallback, normalized_key, device), meta}

              existing ->
                if should_replace_record?(existing, device) do
                  {canonical, Map.put(fallback, normalized_key, device), meta}
                else
                  {canonical, fallback,
                   %{meta | skipped_non_canonical: meta.skipped_non_canonical + 1}}
                end
            end

          _existing ->
            # Canonical record exists, skip this one
            {canonical, fallback, %{meta | skipped_non_canonical: meta.skipped_non_canonical + 1}}
        end
      end
    end
  end

  defp get_canonical_device_id(device) do
    metadata = device.metadata || %{}
    String.trim(metadata["canonical_device_id"] || "")
  end

  defp is_service_device?(device_id) do
    # Service devices have specific prefixes
    String.starts_with?(device_id, "poller:") or
      String.starts_with?(device_id, "agent:") or
      String.starts_with?(device_id, "svc:")
  end

  defp should_replace_record?(existing, candidate) do
    existing_last_seen = existing.last_seen_at
    candidate_last_seen = candidate.last_seen_at

    cond do
      # Prefer records with last_seen
      is_nil(existing_last_seen) and not is_nil(candidate_last_seen) ->
        true

      not is_nil(existing_last_seen) and is_nil(candidate_last_seen) ->
        false

      # Prefer more recent records
      not is_nil(candidate_last_seen) and not is_nil(existing_last_seen) ->
        DateTime.compare(candidate_last_seen, existing_last_seen) == :gt

      # Prefer available records
      candidate.is_available and not existing.is_available ->
        true

      not candidate.is_available and existing.is_available ->
        false

      # Tie-breaker: lexicographic order
      true ->
        String.trim(candidate.uid || "") < String.trim(existing.uid || "")
    end
  end

  defp compute_device_stats(devices, snapshot, meta, state) do
    active_threshold =
      DateTime.utc_now()
      |> DateTime.add(-state.active_window, :millisecond)

    partitions = %{}

    {snapshot, partitions} =
      Enum.reduce(devices, {snapshot, partitions}, fn device, {snap, parts} ->
        # Count total
        snap = %{snap | total_devices: snap.total_devices + 1}

        # Get partition
        partition_id = partition_from_device_id(device.uid)
        parts = update_partition_stats(parts, partition_id, :device_count, 1)

        # Count available
        {snap, parts} =
          if device.is_available do
            snap = %{snap | available_devices: snap.available_devices + 1}
            parts = update_partition_stats(parts, partition_id, :available_count, 1)
            {snap, parts}
          else
            {snap, parts}
          end

        # Count active
        {snap, parts} =
          if not is_nil(device.last_seen_at) and
               DateTime.compare(device.last_seen_at, active_threshold) == :gt do
            snap = %{snap | active_devices: snap.active_devices + 1}
            parts = update_partition_stats(parts, partition_id, :active_count, 1)
            {snap, parts}
          else
            {snap, parts}
          end

        # Count capabilities
        snap = count_capabilities(snap, device)

        {snap, parts}
      end)

    snapshot = %{
      snapshot
      | unavailable_devices: snapshot.total_devices - snapshot.available_devices,
        partitions: build_partition_list(partitions)
    }

    {snapshot, meta}
  end

  defp partition_from_device_id(device_id) when is_binary(device_id) do
    case String.split(device_id, ":", parts: 2) do
      [partition, _rest] when partition != "sr" -> partition
      _ -> @default_partition
    end
  end

  defp partition_from_device_id(_), do: @default_partition

  defp update_partition_stats(partitions, partition_id, field, increment) do
    stats = Map.get(partitions, partition_id, %PartitionStats{partition_id: partition_id})
    updated = Map.update!(stats, field, &(&1 + increment))
    Map.put(partitions, partition_id, updated)
  end

  defp build_partition_list(partitions) do
    partitions
    |> Map.values()
    |> Enum.sort_by(& &1.partition_id)
  end

  defp count_capabilities(snapshot, device) do
    # Check for collector
    collector_id =
      case device.metadata do
        %{"collector_agent_id" => id} when is_binary(id) and id != "" -> id
        _ -> nil
      end

    snapshot =
      if collector_id != nil or has_any_capability?(device) do
        %{snapshot | devices_with_collectors: snapshot.devices_with_collectors + 1}
      else
        snapshot
      end

    # Count specific capabilities
    capabilities = device.capabilities || []

    snapshot =
      if has_capability?(capabilities, "icmp") do
        %{snapshot | devices_with_icmp: snapshot.devices_with_icmp + 1}
      else
        snapshot
      end

    snapshot =
      if has_capability?(capabilities, "snmp") do
        %{snapshot | devices_with_snmp: snapshot.devices_with_snmp + 1}
      else
        snapshot
      end

    snapshot =
      if has_capability?(capabilities, "sysmon") do
        %{snapshot | devices_with_sysmon: snapshot.devices_with_sysmon + 1}
      else
        snapshot
      end

    snapshot
  end

  defp has_any_capability?(device) do
    capabilities = device.capabilities || []
    length(capabilities) > 0
  end

  defp has_capability?(capabilities, name) do
    Enum.any?(capabilities, fn cap ->
      String.downcase(to_string(cap)) == String.downcase(name)
    end)
  end

  defp clone_snapshot(snapshot) do
    %Snapshot{
      timestamp: snapshot.timestamp,
      total_devices: snapshot.total_devices,
      available_devices: snapshot.available_devices,
      unavailable_devices: snapshot.unavailable_devices,
      active_devices: snapshot.active_devices,
      devices_with_collectors: snapshot.devices_with_collectors,
      devices_with_icmp: snapshot.devices_with_icmp,
      devices_with_snmp: snapshot.devices_with_snmp,
      devices_with_sysmon: snapshot.devices_with_sysmon,
      partitions: Enum.map(snapshot.partitions, &struct(PartitionStats, Map.from_struct(&1)))
    }
  end

  defp log_snapshot_refresh(previous, previous_meta, current, meta) do
    # Check if anything changed
    meta_changed =
      meta.raw_records != previous_meta.raw_records or
        meta.processed_records != previous_meta.processed_records or
        meta.skipped_non_canonical != previous_meta.skipped_non_canonical

    stats_changed =
      is_nil(previous) or
        previous.total_devices != current.total_devices or
        previous.available_devices != current.available_devices

    if stats_changed or meta_changed or current.total_devices == 0 do
      Logger.info(
        "Device stats snapshot refreshed: " <>
          "total=#{current.total_devices}, " <>
          "available=#{current.available_devices}, " <>
          "unavailable=#{current.unavailable_devices}, " <>
          "active=#{current.active_devices}, " <>
          "raw=#{meta.raw_records}, " <>
          "processed=#{meta.processed_records}"
      )
    end

    # Warn about non-canonical skips
    if meta.skipped_non_canonical > 0 and
         meta.skipped_non_canonical != previous_meta.skipped_non_canonical do
      Logger.warning(
        "Non-canonical device records filtered: " <>
          "skipped=#{meta.skipped_non_canonical}, " <>
          "previous=#{previous_meta.skipped_non_canonical}"
      )
    end
  end

  defp record_stats_metrics(meta, snapshot) do
    :telemetry.execute(
      [:serviceradar, :stats, :snapshot],
      %{
        total_devices: snapshot.total_devices,
        available_devices: snapshot.available_devices,
        unavailable_devices: snapshot.unavailable_devices,
        active_devices: snapshot.active_devices,
        devices_with_collectors: snapshot.devices_with_collectors,
        devices_with_icmp: snapshot.devices_with_icmp,
        devices_with_snmp: snapshot.devices_with_snmp,
        devices_with_sysmon: snapshot.devices_with_sysmon,
        raw_records: meta.raw_records,
        processed_records: meta.processed_records,
        skipped_non_canonical: meta.skipped_non_canonical,
        inferred_canonical: meta.inferred_canonical_fallback
      },
      %{
        timestamp: snapshot.timestamp
      }
    )
  end

  defp invoke_alert_handler(nil, _previous, _previous_meta, _current, _meta), do: :ok

  defp invoke_alert_handler(handler, previous, previous_meta, current, meta)
       when is_function(handler, 4) do
    try do
      handler.(previous, previous_meta, current, meta)
    rescue
      e ->
        Logger.error("Stats alert handler raised: #{inspect(e)}")
    end
  end

  defp invoke_alert_handler(_handler, previous, _previous_meta, current, meta) do
    # Default handler: check for non-canonical anomaly
    AlertGenerator.stats_anomaly(%{
      raw_records: meta.raw_records,
      processed_records: meta.processed_records,
      skipped_non_canonical: meta.skipped_non_canonical,
      inferred_canonical_fallback: meta.inferred_canonical_fallback,
      total_devices: current.total_devices,
      available_devices: current.available_devices,
      snapshot_timestamp: current.timestamp,
      previous_total_devices: previous && previous.total_devices,
      previous_snapshot_timestamp: previous && previous.timestamp
    })
  end
end
