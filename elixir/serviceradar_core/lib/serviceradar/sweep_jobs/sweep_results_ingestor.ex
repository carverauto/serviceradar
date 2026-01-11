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

  ## Usage

      SweepResultsIngestor.ingest_results(results, execution_id, tenant_id,
        actor: actor
      )
  """

  require Logger

  alias ServiceRadar.Cluster.TenantSchemas
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
  @spec ingest_results([map()], String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def ingest_results(results, execution_id, tenant_id, opts \\ []) do
    actor = Keyword.get(opts, :actor, system_actor(tenant_id))
    tenant_schema = TenantSchemas.schema_for_tenant(tenant_id)
    sweep_group_id = Keyword.get(opts, :sweep_group_id)
    agent_id = Keyword.get(opts, :agent_id)
    config_version = Keyword.get(opts, :config_version)
    scanner_metrics = Keyword.get(opts, :scanner_metrics)

    results = List.wrap(results)
    total_count = length(results)

    Logger.info("SweepResultsIngestor: Processing #{total_count} results for execution #{execution_id}")

    # Ensure execution record exists (creates one if missing)
    case ensure_execution_exists(execution_id, sweep_group_id, agent_id, config_version, tenant_schema, actor) do
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

    # Extract tenant_id for PubSub broadcasts
    broadcast_tenant_id = extract_tenant_id_from_schema(tenant_schema)

    result =
      Enum.reduce_while(batches, {:ok, initial_stats}, fn {batch, batch_num}, {:ok, acc_stats} ->
        batch_start = System.monotonic_time(:millisecond)

        case process_batch(batch, execution_id, tenant_schema, actor) do
          {:ok, batch_stats} ->
            batch_elapsed = System.monotonic_time(:millisecond) - batch_start

            Logger.debug(
              "SweepResultsIngestor: Batch #{batch_num}/#{total_batches} (#{length(batch)} results) completed in #{batch_elapsed}ms"
            )

            merged_stats = merge_stats(acc_stats, batch_stats)

            # Broadcast progress after each batch for real-time UI updates
            SweepPubSub.broadcast_progress(broadcast_tenant_id, execution_id, %{
              batch_num: batch_num,
              total_batches: total_batches,
              hosts_processed: merged_stats.hosts_total,
              hosts_available: merged_stats.hosts_available,
              hosts_failed: merged_stats.hosts_failed,
              devices_created: merged_stats.devices_created,
              devices_updated: merged_stats.devices_updated
            })

            {:cont, {:ok, merged_stats}}

          {:error, reason} ->
            {:halt, {:error, reason}}
        end
      end)

    case result do
      {:ok, final_stats} ->
        # Update execution with final statistics and scanner metrics
        update_execution(execution_id, sweep_group_id, final_stats, scanner_metrics, broadcast_tenant_id, tenant_schema, actor)

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
  @spec ingest_single(map(), String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def ingest_single(result, execution_id, tenant_id, opts \\ []) do
    ingest_results([result], execution_id, tenant_id, opts)
  end

  # Private functions

  defp process_batch(results, execution_id, tenant_schema, actor) do
    # Step 1: Extract all IPs for bulk device lookup
    ips = Enum.map(results, &extract_ip/1) |> Enum.reject(&is_nil/1) |> Enum.uniq()

    # Step 2: Batch lookup existing devices by IP
    device_map = DeviceLookup.batch_lookup_by_ip(ips, actor: actor)

    # Step 3: Find IPs without existing devices
    known_ips = Map.keys(device_map)
    unknown_ips = ips -- known_ips

    # Step 4: Create device records for unknown hosts
    created_devices = create_unknown_devices(unknown_ips, results, tenant_schema)

    # Step 5: Merge known and created devices
    all_devices = Map.merge(device_map, created_devices)

    # Step 6: Build host result records
    {host_results, stats} = build_host_results(results, execution_id, all_devices)

    # Step 7: Bulk insert host results
    case bulk_insert_host_results(host_results, tenant_schema) do
      :ok ->
        # Step 8: Update device availability
        update_device_availability(results, all_devices, tenant_schema)

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

  defp create_unknown_devices([], _results, _tenant_schema), do: %{}

  defp create_unknown_devices(unknown_ips, results, tenant_schema) do
    # Build lookup of result data by IP
    result_by_ip =
      results
      |> Enum.map(fn r -> {extract_ip(r), r} end)
      |> Enum.reject(fn {ip, _} -> is_nil(ip) end)
      |> Map.new()

    timestamp = DateTime.utc_now() |> DateTime.truncate(:second)

    device_records =
      unknown_ips
      |> Enum.map(fn ip ->
        result = Map.get(result_by_ip, ip, %{})
        hostname = result["hostname"]
        is_available = result["icmp_available"] || result["icmpAvailable"] || false

        %{
          uid: generate_device_uid(ip),
          type_id: 0,
          type: "Unknown",
          name: hostname || ip,
          hostname: hostname,
          ip: ip,
          discovery_sources: ["sweep"],
          is_available: is_available,
          first_seen_time: timestamp,
          last_seen_time: timestamp,
          created_time: timestamp,
          modified_time: timestamp,
          metadata: %{}
        }
      end)

    if length(device_records) > 0 do
      # Bulk upsert devices
      case Repo.insert_all(
             {tenant_schema <> ".ocsf_devices", Device},
             device_records,
             on_conflict: {:replace, [:last_seen_time, :is_available, :modified_time]},
             conflict_target: :uid,
             returning: [:uid, :ip]
           ) do
        {_count, created} ->
          # Build map of IP -> canonical record
          created
          |> Enum.map(fn device ->
            {device.ip,
             %{
               canonical_device_id: device.uid,
               partition: "default",
               metadata_hash: nil,
               attributes: %{},
               updated_at: timestamp
             }}
          end)
          |> Map.new()
      end
    else
      %{}
    end
  end

  defp generate_device_uid(ip) do
    "sweep-#{ip}-#{:erlang.phash2(ip)}"
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
        is_available = result["icmp_available"] || result["icmpAvailable"] || false

        status =
          cond do
            is_available -> :available
            result["error"] -> :error
            true -> :unavailable
          end

        # Get device ID from lookup
        device_record = Map.get(device_map, ip)
        device_id = if device_record, do: device_record.canonical_device_id

        # Parse response time (convert ns to ms)
        response_time_ns = result["icmp_response_time_ns"] || result["icmpResponseTimeNs"]
        response_time_ms = if response_time_ns, do: div(response_time_ns, 1_000_000)

        # Parse open ports
        open_ports = result["tcp_ports_open"] || result["tcpPortsOpen"] || []

        record = %{
          id: Ash.UUID.generate(),
          tenant_id: nil,
          execution_id: execution_id,
          ip: ip,
          hostname: result["hostname"],
          status: status,
          response_time_ms: response_time_ms,
          open_ports: open_ports,
          sweep_modes_results: build_modes_results(result),
          device_id: device_id,
          error_message: result["error"],
          inserted_at: DateTime.utc_now()
        }

        updated_stats = %{
          stats
          | hosts_total: stats.hosts_total + 1,
            hosts_available: stats.hosts_available + if(is_available, do: 1, else: 0),
            hosts_failed: stats.hosts_failed + if(is_available, do: 0, else: 1)
        }

        {[record | acc], updated_stats}
      end)

    {Enum.reverse(records), stats}
  end

  defp build_modes_results(result) do
    icmp =
      if result["icmp_available"] || result["icmpAvailable"],
        do: "success",
        else: "failed"

    tcp_ports = result["tcp_ports_open"] || result["tcpPortsOpen"] || []
    tcp = if length(tcp_ports) > 0, do: "success", else: "no_response"

    %{"icmp" => icmp, "tcp" => tcp}
  end

  defp bulk_insert_host_results([], _tenant_schema), do: :ok

  defp bulk_insert_host_results(records, tenant_schema) do
    # Insert directly to table
    case Repo.insert_all(
           {tenant_schema <> ".sweep_host_results", SweepHostResult},
           records,
           on_conflict: :nothing,
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

  defp update_device_availability(results, device_map, tenant_schema) do
    # Group results by availability
    updates_by_status =
      results
      |> Enum.group_by(fn result ->
        result["icmp_available"] || result["icmpAvailable"] || false
      end)

    timestamp = DateTime.utc_now() |> DateTime.truncate(:second)

    # Update available devices
    available_ips =
      updates_by_status
      |> Map.get(true, [])
      |> Enum.map(&extract_ip/1)
      |> Enum.reject(&is_nil/1)

    if length(available_ips) > 0 do
      device_uids =
        available_ips
        |> Enum.map(&Map.get(device_map, &1))
        |> Enum.reject(&is_nil/1)
        |> Enum.map(& &1.canonical_device_id)

      if length(device_uids) > 0 do
        from(d in {tenant_schema <> ".ocsf_devices", Device},
          where: d.uid in ^device_uids
        )
        |> Repo.update_all(
          set: [
            is_available: true,
            last_seen_time: timestamp,
            modified_time: timestamp
          ]
        )

        # Also add "sweep" to discovery_sources if not present
        add_sweep_to_discovery_sources(device_uids, tenant_schema)
      end
    end

    # Update unavailable devices
    unavailable_ips =
      updates_by_status
      |> Map.get(false, [])
      |> Enum.map(&extract_ip/1)
      |> Enum.reject(&is_nil/1)

    if length(unavailable_ips) > 0 do
      device_uids =
        unavailable_ips
        |> Enum.map(&Map.get(device_map, &1))
        |> Enum.reject(&is_nil/1)
        |> Enum.map(& &1.canonical_device_id)

      if length(device_uids) > 0 do
        from(d in {tenant_schema <> ".ocsf_devices", Device},
          where: d.uid in ^device_uids
        )
        |> Repo.update_all(
          set: [
            is_available: false,
            modified_time: timestamp
          ]
        )
      end
    end

    :ok
  end

  defp add_sweep_to_discovery_sources(device_uids, tenant_schema) do
    # Use raw SQL to add "sweep" to array if not present
    # PostgreSQL: array_append with check for existence
    sql = """
    UPDATE #{tenant_schema}.ocsf_devices
    SET discovery_sources = array_append(
      COALESCE(discovery_sources, ARRAY[]::text[]),
      'sweep'
    )
    WHERE uid = ANY($1)
    AND NOT ('sweep' = ANY(COALESCE(discovery_sources, ARRAY[]::text[])))
    """

    Repo.query(sql, [device_uids])
  end

  defp update_execution(execution_id, sweep_group_id, stats, scanner_metrics, tenant_id, tenant_schema, _actor) do
    timestamp = DateTime.utc_now()

    # Calculate duration if we can fetch started_at
    started_at_result =
      from(e in {tenant_schema <> ".sweep_group_executions", SweepGroupExecution},
        where: e.id == ^execution_id,
        select: e.started_at
      )
      |> Repo.one()

    duration_ms =
      case started_at_result do
        nil -> nil
        started_at -> DateTime.diff(timestamp, started_at, :millisecond)
      end

    # Build update fields, including scanner_metrics if present
    update_fields = [
      hosts_total: stats.hosts_total,
      hosts_available: stats.hosts_available,
      hosts_failed: stats.hosts_failed,
      status: :completed,
      completed_at: timestamp,
      duration_ms: duration_ms,
      updated_at: timestamp
    ]

    update_fields =
      if scanner_metrics do
        Keyword.put(update_fields, :scanner_metrics, scanner_metrics)
      else
        update_fields
      end

    from(e in {tenant_schema <> ".sweep_group_executions", SweepGroupExecution},
      where: e.id == ^execution_id
    )
    |> Repo.update_all(set: update_fields)

    # Broadcast execution completion for real-time UI updates
    execution = %{
      id: execution_id,
      sweep_group_id: sweep_group_id,
      started_at: started_at_result,
      completed_at: timestamp,
      duration_ms: duration_ms,
      hosts_total: stats.hosts_total,
      hosts_available: stats.hosts_available,
      hosts_failed: stats.hosts_failed
    }

    SweepPubSub.broadcast_completed(tenant_id, execution, stats)
  end

  defp ensure_execution_exists(execution_id, sweep_group_id, agent_id, config_version, tenant_schema, _actor) do
    # Check if execution exists
    existing =
      from(e in {tenant_schema <> ".sweep_group_executions", SweepGroupExecution},
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
        create_execution(execution_id, sweep_group_id, agent_id, config_version, tenant_schema)
      else
        Logger.warning("SweepResultsIngestor: Cannot create execution - no sweep_group_id provided")
        :ok
      end
    end
  end

  defp create_execution(execution_id, sweep_group_id, agent_id, config_version, tenant_schema) do
    timestamp = DateTime.utc_now() |> DateTime.truncate(:second)

    # Extract tenant_id from schema name (format: "tenant_<uuid>")
    tenant_id = extract_tenant_id_from_schema(tenant_schema)

    record = %{
      id: execution_id,
      tenant_id: tenant_id,
      sweep_group_id: sweep_group_id,
      agent_id: agent_id,
      config_version: config_version,
      status: :running,
      started_at: timestamp,
      hosts_total: 0,
      hosts_available: 0,
      hosts_failed: 0,
      inserted_at: timestamp,
      updated_at: timestamp
    }

    case Repo.insert_all(
           {tenant_schema <> ".sweep_group_executions", SweepGroupExecution},
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
          started_at: timestamp,
          config_version: config_version
        }

        SweepPubSub.broadcast_started(tenant_id, execution)

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

  defp merge_stats(stats1, stats2) do
    %{
      hosts_total: stats1.hosts_total + stats2.hosts_total,
      hosts_available: stats1.hosts_available + stats2.hosts_available,
      hosts_failed: stats1.hosts_failed + stats2.hosts_failed,
      devices_updated: stats1.devices_updated + Map.get(stats2, :devices_updated, 0),
      devices_created: stats1.devices_created + Map.get(stats2, :devices_created, 0)
    }
  end

  defp system_actor(tenant_id) do
    %{
      id: "system",
      role: :super_admin,
      tenant_id: tenant_id
    }
  end

  defp extract_tenant_id_from_schema(tenant_schema) do
    case String.split(tenant_schema, "tenant_") do
      [_, uuid] -> uuid
      _ -> nil
    end
  end
end
