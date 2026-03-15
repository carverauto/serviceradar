defmodule ServiceRadar.SweepJobs.SweepResultsIngestor do
  @moduledoc """
  Ingests sweep results and updates device inventory.

  Processes sweep results from agents and:
  - Stores SweepHostResult records for each scanned host
  - Updates SweepGroupExecution statistics
  - Updates device availability status in inventory
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

  import Ecto.Query

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Ash.Page
  alias ServiceRadar.Identity.DeviceAliasState
  alias ServiceRadar.Identity.DeviceLookup
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Inventory.IdentityReconciler
  alias ServiceRadar.Repo
  alias ServiceRadar.SweepJobs.MapperPromotion
  alias ServiceRadar.SweepJobs.SweepGroup
  alias ServiceRadar.SweepJobs.SweepGroupExecution
  alias ServiceRadar.SweepJobs.SweepHostResult
  alias ServiceRadar.SweepJobs.SweepMonitorWorker
  alias ServiceRadar.SweepJobs.SweepPubSub

  require Ash.Query
  require Logger

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
    mapper_promotion_opts = Keyword.get(opts, :mapper_promotion_opts, [])

    results = List.wrap(results)
    total_count = length(results)

    Logger.info(
      "SweepResultsIngestor: Processing #{total_count} results for execution #{execution_id}"
    )

    # Ensure execution record exists (creates one if missing)
    case ensure_execution_or_skip(
           execution_id,
           sweep_group_id,
           agent_id,
           config_version,
           expected_total_hosts,
           actor
         ) do
      {:skip, reason} ->
        {:error, reason}

      :ok ->
        start_time = System.monotonic_time(:millisecond)

        results
        |> process_batches(execution_id, sweep_group_id, agent_id, actor, mapper_promotion_opts)
        |> finalize_results(
          execution_id,
          sweep_group_id,
          scanner_metrics,
          actor,
          total_count,
          start_time,
          expected_total_hosts: expected_total_hosts,
          chunk_index: chunk_index,
          total_chunks: total_chunks,
          is_final: is_final
        )
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

  defp ensure_execution_or_skip(
         execution_id,
         sweep_group_id,
         agent_id,
         config_version,
         expected_total_hosts,
         actor
       ) do
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

      {:error, :missing_sweep_group_id} ->
        Logger.warning(
          "SweepResultsIngestor: Skipping results for execution #{execution_id} because sweep_group_id is missing"
        )

        {:skip, :missing_sweep_group_id}

      {:error, reason} ->
        Logger.error(
          "SweepResultsIngestor: Failed to ensure execution exists: #{inspect(reason)}"
        )

        # Continue anyway - we'll just update what we can
        :ok
    end
  end

  defp process_batches(
         results,
         execution_id,
         sweep_group_id,
         agent_id,
         actor,
         mapper_promotion_opts
       ) do
    batches =
      results
      |> Enum.chunk_every(@batch_size)
      |> Enum.with_index(1)

    total_batches = max(1, ceil(length(results) / @batch_size))

    initial_stats = %{
      hosts_total: 0,
      hosts_available: 0,
      hosts_failed: 0,
      devices_updated: 0,
      devices_created: 0,
      mapper_dispatched: 0,
      mapper_suppressed: 0,
      mapper_skipped: 0,
      mapper_failed: 0
    }

    Enum.reduce_while(batches, {:ok, initial_stats}, fn {batch, batch_num}, {:ok, acc_stats} ->
      batch_start = System.monotonic_time(:millisecond)

      case process_batch(
             batch,
             execution_id,
             sweep_group_id,
             agent_id,
             actor,
             mapper_promotion_opts
           ) do
        {:ok, batch_stats} ->
          batch_elapsed = System.monotonic_time(:millisecond) - batch_start

          Logger.debug(
            "SweepResultsIngestor: Batch #{batch_num}/#{total_batches} (#{length(batch)} results) completed in #{batch_elapsed}ms"
          )

          merged_stats = merge_stats(acc_stats, batch_stats)

          {:cont, {:ok, merged_stats}}

        {:error, reason} ->
          Logger.error(
            "SweepResultsIngestor: Batch #{batch_num}/#{total_batches} failed: #{inspect(reason)}"
          )

          {:halt, {:error, reason}}
      end
    end)
  end

  defp finalize_results(
         {:ok, final_stats},
         execution_id,
         sweep_group_id,
         scanner_metrics,
         actor,
         total_count,
         start_time,
         opts
       ) do
    execution =
      update_execution(
        execution_id,
        sweep_group_id,
        final_stats,
        scanner_metrics,
        actor,
        opts
      )

    broadcast_execution_progress(
      execution_id,
      execution,
      final_stats,
      Keyword.get(opts, :chunk_index),
      Keyword.get(opts, :total_chunks),
      Keyword.get(opts, :is_final)
    )

    elapsed = System.monotonic_time(:millisecond) - start_time
    rate = if elapsed > 0, do: Float.round(total_count / (elapsed / 1000), 1), else: 0

    Logger.info(
      "SweepResultsIngestor: Completed #{total_count} results in #{elapsed}ms (#{rate}/sec), " <>
        "available: #{final_stats.hosts_available}, failed: #{final_stats.hosts_failed}"
    )

    {:ok, final_stats}
  end

  defp finalize_results(
         {:error, _} = error,
         _execution_id,
         _sweep_group_id,
         _scanner_metrics,
         _actor,
         _total_count,
         _start_time,
         _opts
       ) do
    error
  end

  defp process_batch(
         results,
         execution_id,
         sweep_group_id,
         agent_id,
         actor,
         mapper_promotion_opts
       ) do
    # Step 1: Extract all IPs for bulk device lookup
    ips = results |> Enum.map(&extract_ip/1) |> Enum.reject(&is_nil/1) |> Enum.uniq()

    # Step 2: Batch lookup existing devices by IP (confirmed aliases only)
    # DB connection's search_path determines the schema
    device_map = DeviceLookup.batch_lookup_by_ip(ips, actor: actor, include_deleted: true)

    # Step 3: Find IPs without existing devices
    known_ips = Map.keys(device_map)
    unknown_ips = ips -- known_ips

    # Step 4: Check detected aliases for unknown IPs (fallback before skipping)
    detected_alias_map =
      DeviceLookup.lookup_detected_aliases_by_ip(unknown_ips, actor: actor, include_deleted: true)

    detected_ips = Map.keys(detected_alias_map)

    # Step 4a: Confirm detected aliases that matched sweep results
    confirm_detected_aliases(detected_alias_map, execution_id, actor)

    # Step 4b: Extract device records from detected aliases
    detected_device_map =
      Map.new(detected_alias_map, fn {ip, {record, _alias}} -> {ip, record} end)

    created_device_map =
      create_available_unknown_devices(
        results,
        unknown_ips -- detected_ips,
        sweep_group_id,
        actor
      )

    # Step 5: Merge all device sources
    all_devices =
      device_map
      |> Map.merge(detected_device_map)
      |> Map.merge(created_device_map)

    # Step 7: Build host result records
    {host_results, stats} = build_host_results(results, execution_id, all_devices)

    # Step 8: Bulk insert host results
    case bulk_insert_host_results(host_results) do
      :ok ->
        # Step 9: Update device availability
        update_device_availability(results, all_devices, sweep_group_id, actor)

        promotion_stats =
          MapperPromotion.promote(
            results,
            all_devices,
            sweep_group_id,
            agent_id,
            Keyword.put(mapper_promotion_opts, :actor, actor)
          )

        final_stats =
          stats
          |> Map.put(:devices_created, map_size(created_device_map))
          |> Map.put(:devices_updated, length(known_ips) + length(detected_ips))
          |> Map.put(:aliases_confirmed, length(detected_ips))
          |> Map.merge(prefix_promotion_stats(promotion_stats))

        {:ok, final_stats}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp confirm_detected_aliases(detected_alias_map, execution_id, actor) do
    Enum.each(detected_alias_map, fn {ip, {_record, alias_state}} ->
      metadata = %{"sweep_execution_id" => execution_id, "sweep_ip" => ip}

      case DeviceAliasState.confirm_from_sweep(alias_state, %{metadata: metadata}, actor: actor) do
        {:ok, _confirmed} ->
          Logger.debug(
            "SweepResultsIngestor: Confirmed detected alias #{ip} for device #{alias_state.device_id}"
          )

        {:error, reason} ->
          Logger.warning(
            "SweepResultsIngestor: Failed to confirm alias #{ip}: #{inspect(reason)}"
          )
      end
    end)
  end

  defp prefix_promotion_stats(stats) when is_map(stats) do
    %{
      mapper_dispatched: Map.get(stats, :dispatched, 0),
      mapper_suppressed: Map.get(stats, :suppressed, 0),
      mapper_skipped: Map.get(stats, :skipped, 0),
      mapper_failed: Map.get(stats, :failed, 0)
    }
  end

  defp create_available_unknown_devices(_results, [], _sweep_group_id, _actor), do: %{}

  defp create_available_unknown_devices(results, unknown_ips, sweep_group_id, actor) do
    available_unknown_hosts =
      results
      |> Enum.filter(fn result ->
        ip = extract_ip(result)
        result_available?(result) and ip in unknown_ips
      end)
      |> Enum.reduce(%{}, fn result, acc -> Map.put_new(acc, extract_ip(result), result) end)

    if map_size(available_unknown_hosts) == 0 do
      %{}
    else
      partition = sweep_group_partition(sweep_group_id, actor)

      available_unknown_hosts
      |> Map.values()
      |> Enum.each(&create_available_unknown_device(&1, partition, actor))

      available_unknown_hosts
      |> Map.keys()
      |> DeviceLookup.batch_lookup_by_ip(actor: actor, include_deleted: true)
    end
  end

  defp create_available_unknown_device(result, partition, actor) do
    ip = extract_ip(result)
    hostname = normalize_hostname(result["hostname"])

    ids = %{
      agent_id: nil,
      armis_id: nil,
      integration_id: nil,
      netbox_id: nil,
      mac: nil,
      ip: ip,
      partition: partition
    }

    uid = IdentityReconciler.generate_deterministic_device_id(ids)

    attrs = %{
      uid: uid,
      ip: ip,
      hostname: hostname,
      discovery_sources: ["sweep"],
      is_available: true,
      metadata: %{
        "identity_state" => "provisional",
        "identity_source" => "sweep_ip_seed",
        "canonical_partition" => partition
      }
    }

    case Device
         |> Ash.Changeset.for_create(:create, attrs)
         |> Ash.create(actor: actor) do
      {:ok, _device} ->
        Logger.info("SweepResultsIngestor: Created provisional sweep device #{uid} for #{ip}")

      {:error, %Ash.Error.Invalid{errors: errors}} ->
        if not duplicate_device_conflict?(errors) do
          Logger.warning(
            "SweepResultsIngestor: Failed to create provisional sweep device for #{ip}: #{inspect(errors)}"
          )
        end

      {:error, reason} ->
        Logger.warning(
          "SweepResultsIngestor: Failed to create provisional sweep device for #{ip}: #{inspect(reason)}"
        )
    end
  end

  defp sweep_group_partition(nil, _actor), do: "default"
  defp sweep_group_partition("", _actor), do: "default"

  defp sweep_group_partition(sweep_group_id, actor) do
    case Ash.get(SweepGroup, sweep_group_id, actor: actor) do
      {:ok, %SweepGroup{partition: partition}} when is_binary(partition) and partition != "" ->
        partition

      _ ->
        "default"
    end
  end

  defp normalize_hostname(hostname) when is_binary(hostname) do
    case String.trim(hostname) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_hostname(_), do: nil

  defp duplicate_device_conflict?(errors) when is_list(errors) do
    Enum.any?(errors, fn error ->
      field = Map.get(error, :field)
      message = Exception.message(error)
      field == :uid or field == :ip or String.contains?(message, "has already been taken")
    end)
  end

  defp extract_ip(result) do
    result["host_ip"]
  end

  @doc false
  def build_host_results(results, execution_id, device_map) do
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
    result["available"] || false
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
    # Try multiple field names for response time (different Go structs use different names)
    raw_value =
      result["icmp_response_time_ns"] ||
        result["icmpResponseTimeNs"] ||
        result["response_time"]

    case parse_integer(raw_value) do
      nil -> nil
      0 -> nil
      # Round up to at least 1ms for any non-zero response time
      # Sub-millisecond times (common for local subnet) would otherwise become 0
      value when value < 1_000_000 -> 1
      value -> div(value, 1_000_000)
    end
  end

  defp open_ports(result) do
    ports_from_port_results =
      case result["port_results"] do
        nil ->
          []

        port_results when is_list(port_results) ->
          port_results
          |> Enum.filter(fn pr -> pr["available"] == true end)
          |> Enum.map(fn pr -> pr["port"] end)

        _ ->
          []
      end

    ports_from_port_results
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
    icmp_status = result["icmp_status"]

    icmp =
      cond do
        is_map(icmp_status) && icmp_status["available"] == true -> "success"
        is_map(icmp_status) -> "failed"
        true -> "no_response"
      end

    tcp = if Enum.empty?(open_ports(result)), do: "no_response", else: "success"

    %{"icmp" => icmp, "tcp" => tcp}
  end

  defp bulk_insert_host_results([]), do: :ok

  defp bulk_insert_host_results(records) do
    # DB connection's search_path determines the schema
    # Insert records with ON CONFLICT handling that preserves non-zero response_time_ms
    #
    # The response_time_ms preservation uses: COALESCE(NULLIF(EXCLUDED.response_time_ms, 0), existing)
    # - If new value is 0: NULLIF returns NULL, COALESCE falls back to existing
    # - If new value is non-zero: NULLIF returns it, COALESCE uses the new value
    # - This prevents sweep results with 0ms from overwriting valid response times
    on_conflict_query =
      from(r in SweepHostResult,
        update: [
          set: [
            hostname: fragment("EXCLUDED.hostname"),
            status: fragment("EXCLUDED.status"),
            response_time_ms:
              fragment(
                "COALESCE(NULLIF(EXCLUDED.response_time_ms, 0), ?)",
                r.response_time_ms
              ),
            open_ports: fragment("EXCLUDED.open_ports"),
            sweep_modes_results: fragment("EXCLUDED.sweep_modes_results"),
            device_id: fragment("EXCLUDED.device_id"),
            error_message: fragment("EXCLUDED.error_message")
          ]
        ]
      )

    {count, _} =
      Repo.insert_all(
        SweepHostResult,
        records,
        on_conflict: on_conflict_query,
        conflict_target: [:execution_id, :ip],
        returning: false
      )

    Logger.debug(
      "SweepResultsIngestor: Inserted #{count} host results (preserving non-zero response times)"
    )

    :ok
  rescue
    e ->
      Logger.error("SweepResultsIngestor: Failed to insert host results: #{inspect(e)}")
      {:error, e}
  end

  # Default threshold: require 2 consecutive failures before marking unavailable
  @unavailable_threshold 2

  defp update_device_availability(results, device_map, sweep_group_id, actor) do
    timestamp = DateTime.truncate(DateTime.utc_now(), :second)

    available_ips = result_ips_for_status(results, true)
    unavailable_ips = result_ips_for_status(results, false)

    available_uids = device_uids_for_ips(available_ips, device_map)
    unavailable_uids = device_uids_for_ips(unavailable_ips, device_map)

    restore_deleted_devices(Enum.uniq(available_uids ++ unavailable_uids), actor)

    # DB connection's search_path determines the schema
    # Mark available devices (resets failure count)
    update_device_statuses_available(available_uids, timestamp)

    # Apply hysteresis for unavailable devices
    # Only mark unavailable after consecutive failure threshold is exceeded
    # "Available wins" window is based on sweep interval
    update_device_statuses_with_hysteresis(unavailable_uids, timestamp, sweep_group_id)

    maybe_add_sweep_source(Enum.uniq(available_uids ++ unavailable_uids))

    :ok
  end

  defp restore_deleted_devices([], _actor), do: :ok

  defp restore_deleted_devices(device_uids, actor) do
    case load_deleted_devices(device_uids, actor) do
      {:ok, devices} ->
        devices
        |> eligible_restore_uids()
        |> restore_eligible_devices(actor)

      {:error, reason} ->
        Logger.warning("SweepResultsIngestor: Restore lookup failed", error: inspect(reason))
        :ok
    end
  end

  defp load_deleted_devices(device_uids, actor) do
    Device
    |> Ash.Query.for_read(:read, %{include_deleted: true})
    |> Ash.Query.filter(uid in ^device_uids and not is_nil(deleted_at))
    |> Ash.read(actor: actor)
    |> Page.unwrap()
  end

  defp eligible_restore_uids(devices) do
    devices
    |> Enum.filter(&restore_eligible?/1)
    |> Enum.map(& &1.uid)
  end

  defp restore_eligible_devices([], _actor), do: :ok

  defp restore_eligible_devices(eligible_uids, actor) do
    restore_query =
      Device
      |> Ash.Query.for_read(:read, %{include_deleted: true})
      |> Ash.Query.filter(uid in ^eligible_uids)

    case Ash.bulk_update(restore_query, :restore, %{},
           actor: actor,
           return_records?: false,
           return_errors?: true
         ) do
      %Ash.BulkResult{status: :success} ->
        :ok

      %Ash.BulkResult{status: :partial_success, errors: errors} ->
        Logger.warning("SweepResultsIngestor: Partial restore failures", errors: inspect(errors))

      %Ash.BulkResult{status: :error, errors: errors} ->
        Logger.warning("SweepResultsIngestor: Restore failed", errors: inspect(errors))

      other ->
        Logger.warning("SweepResultsIngestor: Restore unexpected result", result: inspect(other))
    end
  end

  defp restore_eligible?(device) do
    sources =
      device.discovery_sources
      |> List.wrap()
      |> Enum.reject(&is_nil/1)
      |> Enum.map(&to_string/1)

    Enum.any?(sources, fn source -> String.downcase(source) != "sweep" and source != "" end)
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

  # Mark devices as available and reset consecutive failure count
  defp update_device_statuses_available([], _timestamp), do: :ok

  defp update_device_statuses_available(device_uids, timestamp) do
    # DB connection's search_path determines the schema
    # Reset consecutive failure count to 0 when device becomes available
    sql = """
    UPDATE ocsf_devices
    SET
      is_available = true,
      last_seen_time = $2,
      modified_time = $2,
      metadata = jsonb_set(
        COALESCE(metadata, '{}'::jsonb),
        '{sweep_consecutive_failures}',
        '0'
      )
    WHERE uid = ANY($1)
    """

    case Repo.query(sql, [device_uids, timestamp]) do
      {:ok, %{num_rows: count}} ->
        Logger.debug(
          "SweepResultsIngestor: Marked #{count} devices as available (reset failure count)"
        )

      {:error, reason} ->
        Logger.error("SweepResultsIngestor: Failed to mark devices available: #{inspect(reason)}")
    end
  end

  # Default window for "available wins" when sweep interval cannot be determined
  @default_available_wins_window_seconds 60

  # Apply hysteresis for unavailable devices
  # Only marks device as unavailable after threshold consecutive failures
  # "Available wins" - skips devices recently marked available by another sweep
  defp update_device_statuses_with_hysteresis([], _timestamp, _sweep_group_id), do: :ok

  defp update_device_statuses_with_hysteresis(device_uids, timestamp, sweep_group_id) do
    # DB connection's search_path determines the schema
    #
    # Hysteresis logic using metadata.sweep_consecutive_failures:
    # 1. Increment failure count
    # 2. Only set is_available=false if failure count >= threshold
    #
    # "Available wins" logic:
    # - Skip devices that are currently available AND were updated recently
    # - The window is based on the sweep interval (from sweep group config)
    # - This prevents multi-agent conflicts where one agent sees the device
    #   and another doesn't, causing availability flapping
    #
    # This prevents transient network issues from causing availability flapping
    available_wins_window = get_available_wins_window(sweep_group_id)

    available_wins_cutoff = DateTime.add(timestamp, -available_wins_window, :second)

    sql = """
    UPDATE ocsf_devices
    SET
      metadata = jsonb_set(
        COALESCE(metadata, '{}'::jsonb),
        '{sweep_consecutive_failures}',
        to_jsonb(COALESCE((metadata->>'sweep_consecutive_failures')::int, 0) + 1)
      ),
      is_available = CASE
        WHEN COALESCE((metadata->>'sweep_consecutive_failures')::int, 0) + 1 >= $2
        THEN false
        ELSE is_available
      END,
      modified_time = $3
    WHERE uid = ANY($1)
      -- "Available wins" - skip devices recently marked available by another sweep
      -- This prevents multi-agent flapping when one agent can reach device and another can't
      AND NOT (is_available = true AND last_seen_time > $4)
    """

    case Repo.query(sql, [device_uids, @unavailable_threshold, timestamp, available_wins_cutoff]) do
      {:ok, %{num_rows: count}} ->
        skipped = length(device_uids) - count

        if skipped > 0 do
          Logger.info(
            "SweepResultsIngestor: Applied hysteresis to #{count} devices, " <>
              "skipped #{skipped} recently-available devices (available wins, window: #{available_wins_window}s)"
          )
        else
          Logger.debug(
            "SweepResultsIngestor: Applied hysteresis to #{count} devices (threshold: #{@unavailable_threshold})"
          )
        end

      {:error, reason} ->
        Logger.error("SweepResultsIngestor: Failed to apply hysteresis: #{inspect(reason)}")
    end
  end

  # Get the "available wins" window based on the sweep group's configured interval
  defp get_available_wins_window(nil), do: @default_available_wins_window_seconds
  defp get_available_wins_window(""), do: @default_available_wins_window_seconds

  defp get_available_wins_window(sweep_group_id) do
    case Repo.get(SweepGroup, sweep_group_id) do
      nil ->
        Logger.debug(
          "SweepResultsIngestor: Sweep group #{sweep_group_id} not found, using default window"
        )

        @default_available_wins_window_seconds

      %SweepGroup{interval: interval} when is_binary(interval) ->
        SweepMonitorWorker.parse_interval_to_seconds(interval)

      _ ->
        @default_available_wins_window_seconds
    end
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
      updated_at
      |> execution_set_fields(scanner_metrics)
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
      Repo.one(from(e in SweepGroupExecution, where: e.id == ^execution_id, select: e.started_at))

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

  defp maybe_mark_execution_complete(set_fields, false, _completed_at, _duration_ms),
    do: set_fields

  defp maybe_mark_execution_complete(set_fields, true, completed_at, duration_ms) do
    set_fields
    |> Keyword.put(:status, :completed)
    |> Keyword.put(:completed_at, completed_at)
    |> Keyword.put(:duration_ms, duration_ms)
  end

  defp update_execution_row(execution_id, inc_fields, set_fields) do
    Repo.update_all(from(e in SweepGroupExecution, where: e.id == ^execution_id),
      inc: inc_fields,
      set: set_fields
    )
  end

  defp maybe_set_expected_total(_execution_id, nil, _updated_at), do: :ok

  defp maybe_set_expected_total(execution_id, expected_total_hosts, updated_at) do
    Repo.update_all(
      from(e in SweepGroupExecution,
        where:
          e.id == ^execution_id and
            (is_nil(e.hosts_total) or e.hosts_total < ^expected_total_hosts),
        update: [set: [hosts_total: ^expected_total_hosts, updated_at: ^updated_at]]
      ),
      []
    )

    :ok
  end

  defp fetch_execution(execution_id) do
    Repo.one(
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
    )
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
      Repo.one(from(e in SweepGroupExecution, where: e.id == ^execution_id, select: e.id))

    if existing do
      Logger.debug("SweepResultsIngestor: Execution #{execution_id} already exists")
      :ok
    else
      # Check for multi-agent conflicts before creating execution
      detect_multi_agent_conflict(sweep_group_id, agent_id)

      # Create execution record if we have a sweep_group_id
      if sweep_group_id && sweep_group_id != "" do
        create_execution(
          execution_id,
          sweep_group_id,
          agent_id,
          config_version,
          expected_total_hosts
        )
      else
        Logger.warning(
          "SweepResultsIngestor: Cannot create execution - no sweep_group_id provided"
        )

        {:error, :missing_sweep_group_id}
      end
    end
  end

  # Detect when multiple agents are submitting results for the same sweep group
  # This can cause availability flapping as agents overwrite each other's results
  defp detect_multi_agent_conflict(nil, _agent_id), do: :ok
  defp detect_multi_agent_conflict("", _agent_id), do: :ok
  defp detect_multi_agent_conflict(_sweep_group_id, nil), do: :ok
  defp detect_multi_agent_conflict(_sweep_group_id, ""), do: :ok

  defp detect_multi_agent_conflict(sweep_group_id, agent_id) do
    # Check for recent executions from different agents in the last hour
    one_hour_ago = DateTime.add(DateTime.utc_now(), -3600, :second)

    recent_agents =
      Repo.all(
        from(e in SweepGroupExecution,
          where:
            e.sweep_group_id == ^sweep_group_id and e.started_at > ^one_hour_ago and
              not is_nil(e.agent_id) and
              e.agent_id != "",
          select: e.agent_id,
          distinct: true
        )
      )

    other_agents = Enum.reject(recent_agents, &(&1 == agent_id))

    if not Enum.empty?(other_agents) do
      Logger.warning(
        "SweepResultsIngestor: MULTI-AGENT CONFLICT DETECTED for sweep group #{sweep_group_id}. " <>
          "Agent '#{agent_id}' is submitting results, but other agents have also submitted recently: #{inspect(other_agents)}. " <>
          "This can cause availability flapping as agents overwrite each other's results. " <>
          "Consider assigning the sweep group to a single agent, or using agent-specific sweep groups."
      )
    end

    :ok
  end

  defp create_execution(
         execution_id,
         sweep_group_id,
         agent_id,
         config_version,
         expected_total_hosts
       ) do
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
        Logger.info(
          "SweepResultsIngestor: Created execution record #{execution_id} for group #{sweep_group_id}"
        )

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

    Repo.update_all(query,
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
      devices_created: stats1.devices_created + Map.get(stats2, :devices_created, 0),
      mapper_dispatched:
        Map.get(stats1, :mapper_dispatched, 0) + Map.get(stats2, :mapper_dispatched, 0),
      mapper_suppressed:
        Map.get(stats1, :mapper_suppressed, 0) + Map.get(stats2, :mapper_suppressed, 0),
      mapper_skipped: Map.get(stats1, :mapper_skipped, 0) + Map.get(stats2, :mapper_skipped, 0),
      mapper_failed: Map.get(stats1, :mapper_failed, 0) + Map.get(stats2, :mapper_failed, 0),
      aliases_confirmed:
        Map.get(stats1, :aliases_confirmed, 0) + Map.get(stats2, :aliases_confirmed, 0)
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
