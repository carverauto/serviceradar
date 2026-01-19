defmodule ServiceRadar.SweepJobs.SweepResultsIngestor do
  @moduledoc """
  Ingests sweep results and updates device inventory.

  Processes sweep results from gateway/agents and:
  - Stores SweepHostResult records for each scanned host
  - Updates SweepGroupExecution statistics
  - Updates device availability status in inventory
  - Creates new device records for unknown hosts
  - Adds "sweep" to discovery_sources array

  ## Message Format

  Expects sweep results in OCSF network activity format:

      %{
        "execution_id" => "uuid",
        "host_ip" => "192.168.1.100",
        "hostname" => "server1",
        "icmp_available" => true,
        "icmp_response_time_ns" => 1500000,
        "tcp_ports_open" => [22, 80],
        "last_sweep_time" => "2024-01-01T00:00:00Z"
      }

  ## Schema Isolation

  This module operates in schema-agnostic mode where the database connection's
  search_path (set by CNPG credentials) determines the schema.

  ## Usage

      SweepResultsIngestor.ingest_results(results, execution_id,
        actor: actor
      )
  """

  require Logger

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Identity.DeviceLookup
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Repo
  alias ServiceRadar.SweepJobs.{SweepGroupExecution, SweepHostResult, SweepPubSub}

  import Ecto.Query

  # Process in chunks to balance memory vs DB efficiency
  @batch_size 500

  @doc """
  Ingest a batch of sweep results for an execution.

  ## Options
  - `:actor` - The actor performing the operation (defaults to system actor)
  - `:sweep_group_id` - The sweep group UUID (required to create execution if missing)
  - `:agent_id` - The agent that performed the sweep
  - `:config_version` - Config version hash for the execution
  - `:scanner_metrics` - Scanner performance metrics from the agent

  Returns {:ok, stats} with processed counts or {:error, reason}.
  """
  @spec ingest_results([map()], String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def ingest_results(results, execution_id, opts \\ []) do
    # DB connection's search_path determines the schema
    actor = Keyword.get(opts, :actor, SystemActor.system(:sweep_results_ingestor))
    sweep_group_id = Keyword.get(opts, :sweep_group_id)
    agent_id = Keyword.get(opts, :agent_id)
    config_version = Keyword.get(opts, :config_version)
    scanner_metrics = Keyword.get(opts, :scanner_metrics)
    expected_total_hosts = Keyword.get(opts, :expected_total_hosts)
    chunk_index = Keyword.get(opts, :chunk_index)
    total_chunks = Keyword.get(opts, :total_chunks)
    is_final = Keyword.get(opts, :is_final, true)

    results = List.wrap(results)
    total_count = length(results)

    Logger.info("SweepResultsIngestor: Processing #{total_count} results for execution #{execution_id}")

    # Ensure execution record exists (creates one if missing)
    case ensure_execution_exists(
           execution_id,
           sweep_group_id,
           agent_id,
           config_version,
           expected_total_hosts,
           actor
         ) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error("SweepResultsIngestor: Failed to ensure execution exists: #{inspect(reason)}")
        # Continue anyway - we'll just update what we can
        :ok
    end
    start_time = System.monotonic_time(:millisecond)

    # Process in batches
    batches =
      results
      |> Enum.chunk_every(@batch_size)
      |> Enum.with_index(1)

    total_batches = max(1, ceil(total_count / @batch_size))

    # Accumulate stats across batches
    initial_stats = %{
      hosts_total: 0,
      hosts_available: 0,
      hosts_failed: 0,
      devices_updated: 0,
      devices_created: 0
    }

    result =
      Enum.reduce_while(batches, {:ok, initial_stats}, fn {batch, batch_num}, {:ok, acc_stats} ->
        batch_start = System.monotonic_time(:millisecond)

        case process_batch(batch, execution_id, actor) do
          {:ok, batch_stats} ->
            batch_elapsed = System.monotonic_time(:millisecond) - batch_start

            Logger.debug(
              "SweepResultsIngestor: Batch #{batch_num}/#{total_batches} (#{length(batch)} results) completed in #{batch_elapsed}ms"
            )

            merged_stats = merge_stats(acc_stats, batch_stats)

            {:cont, {:ok, merged_stats}}

          {:error, reason} ->
            {:halt, {:error, reason}}
        end
      end)

    case result do
      {:ok, final_stats} ->
        # Update execution with final statistics and scanner metrics
        execution =
          update_execution(
          execution_id,
          sweep_group_id,
          final_stats,
          scanner_metrics,
          actor,
          expected_total_hosts: expected_total_hosts,
          chunk_index: chunk_index,
          total_chunks: total_chunks,
          is_final: is_final
        )

        broadcast_execution_progress(
          execution_id,
          execution,
          final_stats,
          chunk_index,
          total_chunks,
          is_final
        )

        elapsed = System.monotonic_time(:millisecond) - start_time
        rate = if elapsed > 0, do: Float.round(total_count / (elapsed / 1000), 1), else: 0

        Logger.info(
          "SweepResultsIngestor: Completed #{total_count} results in #{elapsed}ms (#{rate}/sec), " <>
            "available: #{final_stats.hosts_available}, failed: #{final_stats.hosts_failed}"
        )

        {:ok, final_stats}

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Process a single sweep result.

  Convenience function for processing individual results (e.g., from streaming).
  """
  @spec ingest_single(map(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def ingest_single(result, execution_id, opts \\ []) do
    ingest_results([result], execution_id, opts)
  end

  # Private functions

  defp process_batch(results, execution_id, actor) do
    # Step 1: Extract all IPs for bulk device lookup
    ips = Enum.map(results, &extract_ip/1) |> Enum.reject(&is_nil/1) |> Enum.uniq()

    # Step 2: Batch lookup existing devices by IP
    # DB connection's search_path determines the schema
    device_map = DeviceLookup.batch_lookup_by_ip(ips, actor: actor)

    # Step 3: Find IPs without existing devices
    known_ips = Map.keys(device_map)
    unknown_ips = ips -- known_ips

    # Step 4: Create device records for unknown hosts
    created_devices = create_unknown_devices(unknown_ips, results)

    # Step 5: Merge known and created devices
    all_devices = Map.merge(device_map, created_devices)

    # Step 6: Build host result records
    {host_results, stats} = build_host_results(results, execution_id, all_devices)

    # Step 7: Bulk insert host results
    case bulk_insert_host_results(host_results) do
      :ok ->
        # Step 8: Update device availability
        update_device_availability(results, all_devices)

        final_stats =
          stats
          |> Map.put(:devices_created, length(Map.keys(created_devices)))
          |> Map.put(:devices_updated, length(known_ips))

        {:ok, final_stats}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp extract_ip(result) do
    result["host_ip"] || result["hostIp"] || result["ip"]
  end

  defp create_unknown_devices([], _results), do: %{}

  defp create_unknown_devices(unknown_ips, results) do
    # Build lookup of result data by IP
    result_by_ip =
      results
      |> Enum.map(fn r -> {extract_ip(r), r} end)
      |> Enum.reject(fn {ip, _} -> is_nil(ip) end)
      |> Map.new()

    timestamp = DateTime.utc_now() |> DateTime.truncate(:second)

    device_records = build_unknown_device_records(unknown_ips, result_by_ip, timestamp)
    insert_unknown_device_records(device_records, timestamp)
  end

  defp generate_device_uid(ip) do
    "sweep-#{ip}-#{:erlang.phash2(ip)}"
  end

  defp build_unknown_device_records(unknown_ips, result_by_ip, timestamp) do
    Enum.map(unknown_ips, fn ip ->
      result = Map.get(result_by_ip, ip, %{})
      hostname = result["hostname"]

      %{
        uid: generate_device_uid(ip),
        type_id: 0,
        type: "Unknown",
        name: hostname || ip,
        hostname: hostname,
        ip: ip,
        discovery_sources: ["sweep"],
        is_available: result_available?(result),
        first_seen_time: timestamp,
        last_seen_time: timestamp,
        created_time: timestamp,
        modified_time: timestamp,
        metadata: %{}
      }
    end)
  end

  defp insert_unknown_device_records([], _timestamp), do: %{}

  defp insert_unknown_device_records(device_records, timestamp) do
    # DB connection's search_path determines the schema
    case Repo.insert_all(
           Device,
           device_records,
           on_conflict: {:replace, [:last_seen_time, :is_available, :modified_time]},
           conflict_target: :uid,
           returning: [:uid, :ip]
         ) do
      {_count, created} ->
        created
        |> Enum.map(&device_map_entry(&1, timestamp))
        |> Map.new()
    end
  end

  defp device_map_entry(device, timestamp) do
    {device.ip,
     %{
       canonical_device_id: device.uid,
       partition: "default",
       metadata_hash: nil,
       attributes: %{},
       updated_at: timestamp
     }}
  end

  defp build_host_results(results, execution_id, device_map) do
    initial_stats = %{
      hosts_total: 0,
      hosts_available: 0,
      hosts_failed: 0
    }

    {records, stats} =
      Enum.reduce(results, {[], initial_stats}, fn result, {acc, stats} ->
        ip = extract_ip(result)
        is_available = result_available?(result)
        status = host_status(result, is_available)
        device_id = device_id_for_ip(device_map, ip)

        record =
          build_host_record(result, execution_id, ip, status, device_id)

        updated_stats = update_host_stats(stats, is_available)

        {[record | acc], updated_stats}
      end)

    {Enum.reverse(records), stats}
  end

  defp result_available?(result) do
    result["icmp_available"] || result["icmpAvailable"] || false
  end

  defp host_status(_result, true), do: :available
  defp host_status(result, false), do: if(result["error"], do: :error, else: :unavailable)

  defp device_id_for_ip(device_map, ip) do
    case Map.get(device_map, ip) do
      nil -> nil
      device_record -> device_record.canonical_device_id
    end
  end

  defp build_host_record(result, execution_id, ip, status, device_id) do
    # DB connection's search_path determines the schema
    %{
      id: Ash.UUID.generate(),
      execution_id: execution_id,
      ip: ip,
      hostname: result["hostname"],
      status: status,
      response_time_ms: response_time_ms(result),
      open_ports: open_ports(result),
      sweep_modes_results: build_modes_results(result),
      device_id: device_id,
      error_message: result["error"],
      inserted_at: DateTime.utc_now()
    }
  end

  defp response_time_ms(result) do
    case parse_integer(result["icmp_response_time_ns"] || result["icmpResponseTimeNs"]) do
      nil -> nil
      value -> div(value, 1_000_000)
    end
  end

  defp open_ports(result) do
    result["tcp_ports_open"] || result["tcpPortsOpen"] || []
    |> List.wrap()
    |> Enum.map(&parse_integer/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.filter(&valid_port?/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp parse_integer(value) when is_integer(value), do: value

  defp parse_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} -> parsed
      _ -> nil
    end
  end

  defp parse_integer(_), do: nil

  defp valid_port?(port) when is_integer(port), do: port >= 1 and port <= 65_535

  defp update_host_stats(stats, is_available) do
    %{
      stats
      | hosts_total: stats.hosts_total + 1,
        hosts_available: stats.hosts_available + if(is_available, do: 1, else: 0),
        hosts_failed: stats.hosts_failed + if(is_available, do: 0, else: 1)
    }
  end

  defp build_modes_results(result) do
    icmp = if result_available?(result), do: "success", else: "failed"
    tcp = if Enum.empty?(open_ports(result)), do: "no_response", else: "success"

    %{"icmp" => icmp, "tcp" => tcp}
  end

  defp bulk_insert_host_results([]), do: :ok

  defp bulk_insert_host_results(records) do
    # DB connection's search_path determines the schema
    case Repo.insert_all(
           SweepHostResult,
           records,
           on_conflict:
             {:replace,
              [
                :hostname,
                :status,
                :response_time_ms,
                :sweep_modes_results,
                :open_ports,
                :error_message,
                :device_id
              ]},
           conflict_target: [:execution_id, :ip],
           returning: false
         ) do
      {count, _} ->
        Logger.debug("SweepResultsIngestor: Inserted #{count} host results")
        :ok
    end
  rescue
    e ->
      Logger.error("SweepResultsIngestor: Failed to insert host results: #{inspect(e)}")
      {:error, e}
  end

  defp update_device_availability(results, device_map) do
    timestamp = DateTime.utc_now() |> DateTime.truncate(:second)

    available_ips = result_ips_for_status(results, true)
    unavailable_ips = result_ips_for_status(results, false)

    available_uids = device_uids_for_ips(available_ips, device_map)
    unavailable_uids = device_uids_for_ips(unavailable_ips, device_map)

    # DB connection's search_path determines the schema
    update_device_statuses(available_uids, true, timestamp)
    update_device_statuses(unavailable_uids, false, timestamp)

    maybe_add_sweep_source(Enum.uniq(available_uids ++ unavailable_uids))

    :ok
  end

  defp result_ips_for_status(results, desired) do
    results
    |> Enum.filter(fn result -> result_available?(result) == desired end)
    |> Enum.map(&extract_ip/1)
    |> Enum.reject(&is_nil/1)
  end

  defp device_uids_for_ips(ips, device_map) do
    ips
    |> Enum.map(&Map.get(device_map, &1))
    |> Enum.reject(&is_nil/1)
    |> Enum.map(& &1.canonical_device_id)
    |> Enum.reject(&is_nil/1)
  end

  defp update_device_statuses([], _available, _timestamp), do: :ok

  defp update_device_statuses(device_uids, true, timestamp) do
    # DB connection's search_path determines the schema
    from(d in Device,
      where: d.uid in ^device_uids
    )
    |> Repo.update_all(
      set: [
        is_available: true,
        last_seen_time: timestamp,
        modified_time: timestamp
      ]
    )
  end

  defp update_device_statuses(device_uids, false, timestamp) do
    # DB connection's search_path determines the schema
    from(d in Device,
      where: d.uid in ^device_uids
    )
    |> Repo.update_all(
      set: [
        is_available: false,
        modified_time: timestamp
      ]
    )
  end

  defp maybe_add_sweep_source([]), do: :ok
  defp maybe_add_sweep_source(device_uids) do
    add_sweep_to_discovery_sources(device_uids)
  end

  defp add_sweep_to_discovery_sources(device_uids) do
    # DB connection's search_path determines the schema
    # Use unqualified table name since search_path is set by CNPG credentials
    sql = """
    UPDATE ocsf_devices
    SET discovery_sources = array_append(
      COALESCE(discovery_sources, ARRAY[]::text[]),
      'sweep'
    )
    WHERE uid = ANY($1)
    AND NOT ('sweep' = ANY(COALESCE(discovery_sources, ARRAY[]::text[])))
    """

    _ = Repo.query(sql, [device_uids])
    :ok
  end

  defp update_execution(execution_id, _sweep_group_id, stats, scanner_metrics, _actor, opts) do
    expected_total_hosts = Keyword.get(opts, :expected_total_hosts)
    is_final = Keyword.get(opts, :is_final, true)

    {completed_at, updated_at} = execution_timestamps(is_final)
    duration_ms = execution_duration_ms(execution_id, is_final, completed_at)
    inc_fields = execution_inc_fields(stats, expected_total_hosts)

    set_fields =
      execution_set_fields(updated_at, scanner_metrics)
      |> maybe_mark_execution_complete(is_final, completed_at, duration_ms)

    update_execution_row(execution_id, inc_fields, set_fields)
    maybe_set_expected_total(execution_id, expected_total_hosts, updated_at)
    fetch_execution(execution_id)
  end

  defp execution_timestamps(true) do
    now = DateTime.utc_now()
    {DateTime.truncate(now, :second), DateTime.truncate(now, :microsecond)}
  end

  defp execution_timestamps(false) do
    now = DateTime.utc_now()
    {nil, DateTime.truncate(now, :microsecond)}
  end

  defp execution_duration_ms(_execution_id, false, _completed_at), do: nil

  defp execution_duration_ms(execution_id, true, completed_at) do
    started_at =
      from(e in SweepGroupExecution,
        where: e.id == ^execution_id,
        select: e.started_at
      )
      |> Repo.one()

    case started_at do
      nil -> nil
      _ -> DateTime.diff(completed_at, started_at, :millisecond)
    end
  end

  defp execution_inc_fields(stats, nil) do
    [
      hosts_available: stats.hosts_available,
      hosts_failed: stats.hosts_failed,
      hosts_total: stats.hosts_total
    ]
  end

  defp execution_inc_fields(stats, _expected_total_hosts) do
    [
      hosts_available: stats.hosts_available,
      hosts_failed: stats.hosts_failed
    ]
  end

  defp execution_set_fields(updated_at, scanner_metrics) do
    set_fields = [updated_at: updated_at]

    if scanner_metrics do
      Keyword.put(set_fields, :scanner_metrics, scanner_metrics)
    else
      set_fields
    end
  end

  defp maybe_mark_execution_complete(set_fields, false, _completed_at, _duration_ms), do: set_fields

  defp maybe_mark_execution_complete(set_fields, true, completed_at, duration_ms) do
    set_fields
    |> Keyword.put(:status, :completed)
    |> Keyword.put(:completed_at, completed_at)
    |> Keyword.put(:duration_ms, duration_ms)
  end

  defp update_execution_row(execution_id, inc_fields, set_fields) do
    from(e in SweepGroupExecution,
      where: e.id == ^execution_id
    )
    |> Repo.update_all(inc: inc_fields, set: set_fields)
  end

  defp maybe_set_expected_total(_execution_id, nil, _updated_at), do: :ok

  defp maybe_set_expected_total(execution_id, expected_total_hosts, updated_at) do
    from(e in SweepGroupExecution,
      where: e.id == ^execution_id and (is_nil(e.hosts_total) or e.hosts_total < ^expected_total_hosts),
      update: [set: [hosts_total: ^expected_total_hosts, updated_at: ^updated_at]]
    )
    |> Repo.update_all([])

    :ok
  end

  defp fetch_execution(execution_id) do
    from(e in SweepGroupExecution,
      where: e.id == ^execution_id,
      select: %{
        id: e.id,
        sweep_group_id: e.sweep_group_id,
        agent_id: e.agent_id,
        started_at: e.started_at,
        completed_at: e.completed_at,
        duration_ms: e.duration_ms,
        hosts_total: e.hosts_total,
        hosts_available: e.hosts_available,
        hosts_failed: e.hosts_failed
      }
    )
    |> Repo.one()
  end

  defp ensure_execution_exists(
         execution_id,
         sweep_group_id,
         agent_id,
         config_version,
         expected_total_hosts,
         _actor
       ) do
    # DB connection's search_path determines the schema
    # Check if execution exists
    existing =
      from(e in SweepGroupExecution,
        where: e.id == ^execution_id,
        select: e.id
      )
      |> Repo.one()

    if existing do
      Logger.debug("SweepResultsIngestor: Execution #{execution_id} already exists")
      :ok
    else
      # Create execution record if we have a sweep_group_id
      if sweep_group_id && sweep_group_id != "" do
        create_execution(execution_id, sweep_group_id, agent_id, config_version, expected_total_hosts)
      else
        Logger.warning("SweepResultsIngestor: Cannot create execution - no sweep_group_id provided")
        :ok
      end
    end
  end

  defp create_execution(execution_id, sweep_group_id, agent_id, config_version, expected_total_hosts) do
    now = DateTime.utc_now()
    started_at = DateTime.truncate(now, :second)
    inserted_at = DateTime.truncate(now, :microsecond)
    hosts_total = expected_total_hosts || 0

    mark_superseded_executions(sweep_group_id, agent_id, started_at)

    # DB connection's search_path determines the schema
    record = %{
      id: execution_id,
      sweep_group_id: sweep_group_id,
      agent_id: agent_id,
      config_version: config_version,
      status: :running,
      started_at: started_at,
      hosts_total: hosts_total,
      hosts_available: 0,
      hosts_failed: 0,
      inserted_at: inserted_at,
      updated_at: inserted_at
    }

    case Repo.insert_all(
           SweepGroupExecution,
           [record],
           on_conflict: :nothing,
           returning: false
         ) do
      {1, _} ->
        Logger.info("SweepResultsIngestor: Created execution record #{execution_id} for group #{sweep_group_id}")

        # Broadcast new execution for real-time UI updates
        execution = %{
          id: execution_id,
          sweep_group_id: sweep_group_id,
          agent_id: agent_id,
          started_at: started_at,
          config_version: config_version
        }

        SweepPubSub.broadcast_started(execution)

        :ok

      {0, _} ->
        # Record already exists (race condition), that's fine
        Logger.debug("SweepResultsIngestor: Execution #{execution_id} already exists (race)")
        :ok
    end
  rescue
    e ->
      Logger.error("SweepResultsIngestor: Failed to create execution: #{inspect(e)}")
      {:error, e}
  end

  defp mark_superseded_executions(nil, _agent_id, _now), do: :ok
  defp mark_superseded_executions("", _agent_id, _now), do: :ok

  defp mark_superseded_executions(sweep_group_id, agent_id, now) do
    base_query =
      from(e in SweepGroupExecution,
        where: e.sweep_group_id == ^sweep_group_id and e.status == :running
      )

    query =
      if is_binary(agent_id) and agent_id != "" do
        from(e in base_query, where: e.agent_id == ^agent_id)
      else
        base_query
      end

    query
    |> Repo.update_all(
      set: [
        status: :failed,
        completed_at: now,
        updated_at: DateTime.truncate(DateTime.utc_now(), :microsecond),
        error_message: "superseded by new execution"
      ]
    )

    :ok
  end

  defp merge_stats(stats1, stats2) do
    %{
      hosts_total: stats1.hosts_total + stats2.hosts_total,
      hosts_available: stats1.hosts_available + stats2.hosts_available,
      hosts_failed: stats1.hosts_failed + stats2.hosts_failed,
      devices_updated: stats1.devices_updated + Map.get(stats2, :devices_updated, 0),
      devices_created: stats1.devices_created + Map.get(stats2, :devices_created, 0)
    }
  end

  defp broadcast_execution_progress(
         execution_id,
         execution,
         stats,
         chunk_index,
         total_chunks,
         is_final
       ) do
    if is_nil(execution) do
      :ok
    else
      hosts_available = execution.hosts_available || 0
      hosts_failed = execution.hosts_failed || 0
      hosts_processed = hosts_available + hosts_failed

      progress = %{
        sweep_group_id: Map.get(execution, :sweep_group_id),
        agent_id: Map.get(execution, :agent_id),
        started_at: Map.get(execution, :started_at),
        batch_num: (chunk_index || 0) + 1,
        total_batches: total_chunks || 1,
        hosts_processed: hosts_processed,
        hosts_available: hosts_available,
        hosts_failed: hosts_failed,
        hosts_total: Map.get(execution, :hosts_total) || 0,
        devices_created: stats.devices_created,
        devices_updated: stats.devices_updated
      }

      SweepPubSub.broadcast_progress(execution_id, progress)

      if is_final do
        SweepPubSub.broadcast_completed(execution, %{
          hosts_total: execution.hosts_total,
          hosts_available: hosts_available,
          hosts_failed: hosts_failed,
          devices_created: stats.devices_created,
          devices_updated: stats.devices_updated
        })
      end
    end
  end
end
