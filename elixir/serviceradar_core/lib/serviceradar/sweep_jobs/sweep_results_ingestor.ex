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
  alias ServiceRadar.Infrastructure.Agent
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Inventory.DeviceAgentAvailability
  alias ServiceRadar.Inventory.IdentityReconciler
  alias ServiceRadar.Repo
  alias ServiceRadar.SweepJobs.AvailabilityEvents
  alias ServiceRadar.SweepJobs.MapperPromotion
  alias ServiceRadar.SweepJobs.PortCoverage
  alias ServiceRadar.SweepJobs.SweepGroup
  alias ServiceRadar.SweepJobs.SweepGroupExecution
  alias ServiceRadar.SweepJobs.SweepHostResult
  alias ServiceRadar.SweepJobs.SweepMonitorWorker
  alias ServiceRadar.SweepJobs.SweepPubSub

  require Ash.Query
  require Logger

  # Process in chunks to balance memory vs DB efficiency
  @batch_size 500
  @active_ip_unique_constraint "ocsf_devices_unique_active_ip_idx"
  @banner_grab_audit_failed_event [:serviceradar, :sweep, :banner_grab, :audit_failed]
  @banner_grab_counter_dropped_event [
    :serviceradar,
    :sweep,
    :banner_grab,
    :counter_dropped
  ]
  # Allowlist of counter keys persisted into the audit `counters` map alongside
  # the expected value type. Values that do not satisfy the type are dropped
  # from the persisted summary (and emit a `:counter_dropped` telemetry event)
  # to prevent untrusted agent payloads from injecting hostile values
  # (negative ints, floats, binaries, maps, lists, etc.) into the audit row.
  @banner_grab_counter_keys %{
    "sweep_banner_grab_candidates_total" => :non_neg_integer,
    "sweep_banner_grab_probes_total" => :non_neg_integer,
    "sweep_banner_grab_match_batches_total" => :non_neg_integer,
    "sweep_banner_grab_match_batch_bytes_total" => :non_neg_integer,
    "sweep_banner_grab_bytes_received_total" => :non_neg_integer,
    "sweep_banner_grab_skipped_fresh_total" => :non_neg_integer,
    "sweep_banner_grab_skipped_backoff_total" => :non_neg_integer,
    "sweep_banner_grab_matches_total" => :non_neg_integer,
    "sweep_banner_grab_empty_response_total" => :non_neg_integer,
    "sweep_banner_grab_connection_reset_total" => :non_neg_integer,
    "sweep_banner_grab_timeout_total" => :non_neg_integer,
    "sweep_banner_grab_errors_total" => :non_neg_integer
  }

  @doc """
  Ingest a batch of sweep results for an execution.

  ## Options
  - `:actor` - The actor performing the operation (defaults to system actor)
  - `:sweep_group_id` - The sweep group UUID (required to create execution if missing)
  - `:agent_id` - Reporter UID claimed by the legacy/body payload (forensic only)
  - `:authenticated_agent_id` - Reporter UID established by the trusted gateway
  - `:authenticated_partition_id` - Reporter partition established by the trusted gateway
  - `:config_version` - Config version hash for the execution
  - `:scanner_metrics` - Scanner performance metrics from the agent
  - `:banner_grab_summary` - Phase-level banner-grab counters from the agent
  - `:request_id` - Optional upstream request/correlation ID for audit rows

  Returns {:ok, stats} with processed counts or {:error, reason}.
  """
  @spec ingest_results([map()], String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def ingest_results(results, execution_id, opts \\ []) do
    # DB connection's search_path determines the schema
    actor = Keyword.get(opts, :actor, SystemActor.system(:sweep_results_ingestor))
    sweep_group_id = Keyword.get(opts, :sweep_group_id)
    reported_agent_id = Keyword.get(opts, :agent_id)
    authenticated_agent_id = Keyword.get(opts, :authenticated_agent_id)
    authenticated_partition_id = Keyword.get(opts, :authenticated_partition_id)
    config_version = Keyword.get(opts, :config_version)
    scanner_metrics = Keyword.get(opts, :scanner_metrics)
    banner_grab_summary = Keyword.get(opts, :banner_grab_summary)
    request_id = Keyword.get(opts, :request_id)
    expected_total_hosts = Keyword.get(opts, :expected_total_hosts)
    chunk_index = Keyword.get(opts, :chunk_index)
    total_chunks = Keyword.get(opts, :total_chunks)
    is_final = Keyword.get(opts, :is_final, true)
    mapper_promotion_opts = Keyword.get(opts, :mapper_promotion_opts, [])

    reporter_context =
      resolve_reporter_context(
        execution_id,
        sweep_group_id,
        reported_agent_id,
        authenticated_agent_id,
        authenticated_partition_id
      )

    log_reporter_context(reporter_context, execution_id)

    results = List.wrap(results)
    total_count = length(results)

    Logger.info(
      "SweepResultsIngestor: Processing #{total_count} results for execution #{execution_id}"
    )

    # Ensure execution record exists (creates one if missing)
    case ensure_execution_or_skip(
           execution_id,
           reporter_context,
           config_version,
           expected_total_hosts,
           actor
         ) do
      {:skip, reason} ->
        {:error, reason}

      {:quarantine, reason} ->
        reporter_context = quarantine_reporter_context(reporter_context, reason)
        persist_quarantined_agent_availability(results, reporter_context, actor)
        {:error, reason}

      :ok ->
        start_time = System.monotonic_time(:millisecond)

        results
        |> process_batches(execution_id, reporter_context, actor, mapper_promotion_opts)
        |> finalize_results(
          execution_id,
          reporter_context.resolved_group_id,
          scanner_metrics,
          actor,
          total_count,
          start_time,
          expected_total_hosts: expected_total_hosts,
          banner_grab_summary: banner_grab_summary,
          request_id: request_id,
          chunk_index: chunk_index,
          total_chunks: total_chunks,
          is_final: is_final,
          reporter_context: reporter_context
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

  defp resolve_reporter_context(
         execution_id,
         supplied_group_id,
         reported_agent_id,
         authenticated_agent_id,
         authenticated_partition_id
       ) do
    execution_result = load_execution_identity(execution_id)
    execution = execution_from_result(execution_result)
    supplied_group_uuid = valid_uuid_or_nil(supplied_group_id)

    {resolved_group_id, group_identity_consistent?} =
      resolve_group_identity(execution, supplied_group_id, supplied_group_uuid)

    group_result = load_sweep_group(resolved_group_id)
    group = group_from_result(group_result)
    authenticated_agent_id = valid_reporter_uid(authenticated_agent_id)
    authenticated_partition_id = valid_partition_id(authenticated_partition_id)
    reported_agent_id = forensic_reporter_uid(reported_agent_id)
    reporter_agent_id = authenticated_agent_id || valid_reporter_uid(reported_agent_id)

    {expectation, expectation_reason} =
      reporter_expectation(
        execution_result,
        execution,
        group_result,
        group,
        group_identity_consistent?,
        authenticated_agent_id,
        authenticated_partition_id
      )

    %{
      authenticated_agent_id: authenticated_agent_id,
      authenticated_partition_id: authenticated_partition_id,
      execution: execution,
      expectation: expectation,
      expectation_reason: expectation_reason,
      group: group,
      reported_agent_id: reported_agent_id,
      reporter_agent_id: reporter_agent_id,
      resolved_group_id: resolved_group_id
    }
  end

  defp load_execution_identity(execution_id) do
    case valid_uuid_or_nil(execution_id) do
      nil ->
        {:error, :invalid_execution_id}

      execution_id ->
        {:ok,
         Repo.one(
           from(e in SweepGroupExecution,
             where: e.id == ^execution_id,
             select: %{
               id: e.id,
               sweep_group_id: e.sweep_group_id,
               agent_id: e.agent_id
             }
           )
         )}
    end
  rescue
    error -> {:error, {:execution_lookup_failed, error}}
  end

  defp execution_from_result({:ok, execution}), do: execution
  defp execution_from_result({:error, _reason}), do: nil

  defp resolve_group_identity(%{sweep_group_id: execution_group_id}, supplied, supplied_uuid) do
    consistent? =
      not identity_supplied?(supplied) or
        (not is_nil(supplied_uuid) and supplied_uuid == execution_group_id)

    {execution_group_id, consistent?}
  end

  defp resolve_group_identity(nil, _supplied, supplied_uuid), do: {supplied_uuid, true}

  defp load_sweep_group(nil), do: {:ok, nil}

  defp load_sweep_group(group_id) do
    {:ok, Repo.get(SweepGroup, group_id)}
  rescue
    error -> {:error, {:group_lookup_failed, error}}
  end

  defp group_from_result({:ok, group}), do: group
  defp group_from_result({:error, _reason}), do: nil

  defp reporter_expectation(
         execution_result,
         execution,
         group_result,
         group,
         group_identity_consistent?,
         authenticated_agent_id,
         authenticated_partition_id
       ) do
    cond do
      is_nil(authenticated_agent_id) ->
        {:unknown, :missing_authenticated_reporter}

      match?({:error, _reason}, execution_result) ->
        {:unknown, :unresolved_execution_identity}

      match?({:error, _reason}, group_result) or is_nil(group) ->
        {:unknown, :unresolved_group_identity}

      not group_identity_consistent? ->
        {:unknown, :conflicting_group_identity}

      not execution_reporter_consistent?(execution, authenticated_agent_id) ->
        {:unknown, :conflicting_execution_reporter}

      group.agent_ids == [] and is_nil(authenticated_partition_id) ->
        {:unknown, :missing_authenticated_partition}

      group.agent_ids == [] and authenticated_partition_id == group.partition ->
        {:expected, :partition_assignment}

      group.agent_ids == [] ->
        {:unexpected, :outside_partition_assignment}

      is_list(group.agent_ids) and authenticated_agent_id in group.agent_ids ->
        {:expected, :selected_assignment}

      is_list(group.agent_ids) ->
        {:unexpected, :outside_assignment}

      true ->
        {:unknown, :malformed_group_assignment}
    end
  end

  defp execution_reporter_consistent?(nil, _authenticated_agent_id), do: true

  defp execution_reporter_consistent?(%{agent_id: execution_agent_id}, authenticated_agent_id)
       when execution_agent_id in [nil, ""], do: not is_nil(authenticated_agent_id)

  defp execution_reporter_consistent?(%{agent_id: execution_agent_id}, authenticated_agent_id),
    do: valid_reporter_uid(execution_agent_id) == authenticated_agent_id

  defp identity_supplied?(value) when is_binary(value), do: String.trim(value) != ""
  defp identity_supplied?(nil), do: false
  defp identity_supplied?(_value), do: true

  defp valid_reporter_uid(value) when is_binary(value) do
    if value != "" and String.trim(value) == value, do: value
  end

  defp valid_reporter_uid(_value), do: nil

  defp valid_partition_id(value) when is_binary(value) do
    if value != "" and String.trim(value) == value, do: value
  end

  defp valid_partition_id(_value), do: nil

  defp forensic_reporter_uid(value) when is_binary(value) do
    if String.trim(value) != "", do: value
  end

  defp forensic_reporter_uid(_value), do: nil

  defp log_reporter_context(context, execution_id) do
    maybe_log_reporter_mismatch(context, execution_id)

    case context.expectation do
      :expected ->
        :ok

      :unexpected ->
        Logger.warning(
          "SweepResultsIngestor: ANOMALOUS SWEEP ASSIGNMENT for group " <>
            "#{inspect(context.resolved_group_id)}: authenticated reporter " <>
            "#{inspect(context.authenticated_agent_id)} is outside the persisted assignment"
        )

      :unknown ->
        Logger.warning(
          "SweepResultsIngestor: SWEEP REPORTER EXPECTATION UNKNOWN for execution " <>
            "#{inspect(execution_id)}, group #{inspect(context.resolved_group_id)}, " <>
            "reporter #{inspect(context.reporter_agent_id)}: #{context.expectation_reason}"
        )
    end
  end

  defp maybe_log_reporter_mismatch(
         %{authenticated_agent_id: authenticated, reported_agent_id: reported},
         execution_id
       )
       when is_binary(authenticated) and is_binary(reported) and authenticated != reported do
    Logger.warning(
      "SweepResultsIngestor: SWEEP REPORTER IDENTITY MISMATCH for execution " <>
        "#{inspect(execution_id)}: authenticated reporter #{inspect(authenticated)}, " <>
        "payload reporter #{inspect(reported)}"
    )
  end

  defp maybe_log_reporter_mismatch(_context, _execution_id), do: :ok

  defp ensure_execution_or_skip(
         execution_id,
         reporter_context,
         config_version,
         expected_total_hosts,
         actor
       ) do
    case ensure_execution_exists(
           execution_id,
           reporter_context,
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

      {:error, :unresolved_sweep_group} ->
        Logger.warning(
          "SweepResultsIngestor: Skipping results for execution #{execution_id} because the persisted sweep group cannot be resolved"
        )

        {:skip, :unresolved_sweep_group}

      {:error, reason}
      when reason in [:conflicting_execution_reporter, :conflicting_execution_group] ->
        Logger.warning(
          "SweepResultsIngestor: Quarantining results for execution #{execution_id}: #{reason}"
        )

        {:quarantine, reason}

      {:error, :unresolved_execution_identity} ->
        {:skip, :unresolved_execution_identity}

      {:error, {:execution_lookup_failed, _reason}} = error ->
        {:skip, elem(error, 1)}

      {:error, reason} ->
        Logger.error(
          "SweepResultsIngestor: Failed to ensure execution exists: #{inspect(reason)}"
        )

        # Continue anyway - we'll just update what we can
        :ok
    end
  end

  defp quarantine_reporter_context(reporter_context, reason) do
    %{reporter_context | expectation: :unknown, expectation_reason: reason}
  end

  defp persist_quarantined_agent_availability(results, reporter_context, actor) do
    ips = results |> Enum.map(&extract_ip/1) |> Enum.reject(&is_nil/1) |> Enum.uniq()
    partition = sweep_group_partition(reporter_context.group)

    device_map =
      DeviceLookup.batch_lookup_by_ip(ips,
        actor: actor,
        include_deleted: true,
        use_cache: false,
        partition: partition
      )

    unknown_ips = ips -- Map.keys(device_map)

    detected_device_map =
      unknown_ips
      |> DeviceLookup.lookup_detected_aliases_by_ip(
        actor: actor,
        include_deleted: true,
        partition: partition
      )
      |> Map.new(fn {ip, {record, _alias}} -> {ip, record} end)

    created_device_map =
      create_available_unknown_devices(
        results,
        unknown_ips -- Map.keys(detected_device_map),
        reporter_context.resolved_group_id,
        actor,
        partition
      )

    all_devices =
      device_map
      |> Map.merge(detected_device_map)
      |> Map.merge(created_device_map)

    _accepted =
      upsert_agent_availability(
        results,
        all_devices,
        nil,
        reporter_context,
        utc_now_usec()
      )

    :ok
  end

  defp process_batches(results, execution_id, reporter_context, actor, mapper_promotion_opts) do
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

    batches
    |> Enum.reduce_while({:ok, initial_stats}, fn {batch, batch_num}, {:ok, acc_stats} ->
      batch_start = System.monotonic_time(:millisecond)

      case process_batch(batch, execution_id, reporter_context, actor) do
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
    |> case do
      {:ok, stats} ->
        promotion_stats =
          process_mapper_promotions(
            results,
            reporter_context,
            actor,
            mapper_promotion_opts
          )

        {:ok, merge_stats(stats, promotion_stats)}

      {:error, _} = error ->
        error
    end
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

  defp process_batch(results, execution_id, reporter_context, actor) do
    # Step 1: Extract all IPs for bulk device lookup
    ips = results |> Enum.map(&extract_ip/1) |> Enum.reject(&is_nil/1) |> Enum.uniq()
    partition = sweep_group_partition(reporter_context.group)

    # Step 2: Batch lookup existing devices by IP in this sweep group's partition.
    # Isolation and monitoring copies of the same address must not share status.
    device_map =
      DeviceLookup.batch_lookup_by_ip(ips,
        actor: actor,
        include_deleted: true,
        use_cache: false,
        partition: partition
      )

    # Step 3: Find IPs without existing devices
    known_ips = Map.keys(device_map)
    unknown_ips = ips -- known_ips

    # Step 4: Check detected aliases for unknown IPs (fallback before skipping)
    detected_alias_map =
      DeviceLookup.lookup_detected_aliases_by_ip(unknown_ips,
        actor: actor,
        include_deleted: true,
        partition: partition
      )

    detected_ips = Map.keys(detected_alias_map)

    # Step 4a: Confirm detected aliases only for a resolved authenticated reporter.
    aliases_confirmed =
      maybe_confirm_detected_aliases(
        detected_alias_map,
        execution_id,
        reporter_context,
        actor
      )

    # Step 4b: Extract device records from detected aliases
    detected_device_map =
      Map.new(detected_alias_map, fn {ip, {record, _alias}} -> {ip, record} end)

    created_device_map =
      create_available_unknown_devices(
        results,
        unknown_ips -- detected_ips,
        reporter_context.resolved_group_id,
        actor,
        partition
      )

    # Step 5: Merge all device sources
    all_devices =
      device_map
      |> Map.merge(detected_device_map)
      |> Map.merge(created_device_map)

    # Step 7: Build host result records
    {host_results, stats} =
      build_host_results(results, execution_id, all_devices,
        agent_id: reporter_context.reporter_agent_id,
        sweep_group_id: reporter_context.resolved_group_id
      )

    # Step 8: Bulk insert host results
    case bulk_insert_host_results(host_results) do
      :ok ->
        # Step 9: Update device availability
        update_device_availability(
          results,
          all_devices,
          execution_id,
          reporter_context,
          actor
        )

        final_stats =
          stats
          |> Map.put(:devices_created, map_size(created_device_map))
          |> Map.put(:devices_updated, length(known_ips) + length(detected_ips))
          |> Map.put(:aliases_confirmed, aliases_confirmed)

        {:ok, final_stats}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp maybe_confirm_detected_aliases(detected_alias_map, execution_id, reporter_context, actor) do
    if expected_reporter?(reporter_context) do
      confirm_detected_aliases(detected_alias_map, execution_id, actor)
      map_size(detected_alias_map)
    else
      0
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

  defp process_mapper_promotions([], _reporter_context, _actor, _mapper_promotion_opts) do
    prefix_promotion_stats(%{})
  end

  defp process_mapper_promotions(
         _results,
         %{expectation: expectation},
         _actor,
         _mapper_promotion_opts
       )
       when expectation in [:unexpected, :unknown] do
    prefix_promotion_stats(%{})
  end

  defp process_mapper_promotions(results, reporter_context, actor, mapper_promotion_opts) do
    ips =
      results
      |> Enum.map(&extract_ip/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    partition = sweep_group_partition(reporter_context.group)

    device_map =
      DeviceLookup.batch_lookup_by_ip(ips,
        actor: actor,
        include_deleted: true,
        use_cache: false,
        partition: partition
      )

    results
    |> MapperPromotion.promote(
      device_map,
      reporter_context.resolved_group_id,
      reporter_context.reporter_agent_id,
      Keyword.put(mapper_promotion_opts, :actor, actor)
    )
    |> prefix_promotion_stats()
  end

  defp create_available_unknown_devices(_results, [], _sweep_group_id, _actor, _partition),
    do: %{}

  defp create_available_unknown_devices(results, unknown_ips, _sweep_group_id, actor, partition) do
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
      available_unknown_ips = Map.keys(available_unknown_hosts)

      active_existing_map =
        DeviceLookup.batch_lookup_by_ip(available_unknown_ips,
          actor: actor,
          include_deleted: false,
          use_cache: false,
          partition: partition
        )

      hosts_to_create = Map.drop(available_unknown_hosts, Map.keys(active_existing_map))

      hosts_to_create
      |> Map.values()
      |> Enum.each(&create_available_unknown_device(&1, partition, actor))

      DeviceLookup.batch_lookup_by_ip(available_unknown_ips,
        actor: actor,
        include_deleted: true,
        use_cache: false,
        partition: partition
      )
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
      partition: partition,
      hostname: hostname,
      discovery_sources: ["sweep"],
      # Canonical availability is applied after the device is reloaded through
      # the same expected/configured-source policy as every existing device.
      # Starting fail-closed prevents an unexpected or unattributed reporter
      # from bypassing that policy merely because it discovered a new IP.
      is_available: false,
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

      {:error, reason} ->
        log_provisional_create_error(ip, reason)
    end
  end

  defp log_provisional_create_error(ip, reason) do
    if duplicate_device_conflict?(reason) do
      Logger.debug(
        "SweepResultsIngestor: Provisional sweep device already exists for #{ip}, skipping duplicate create"
      )
    else
      Logger.warning(
        "SweepResultsIngestor: Failed to create provisional sweep device for #{ip}: #{inspect(reason)}"
      )
    end
  end

  defp sweep_group_partition(%SweepGroup{partition: partition})
       when is_binary(partition) and partition != "",
       do: partition

  defp sweep_group_partition(_group), do: "default"

  defp normalize_hostname(hostname) when is_binary(hostname) do
    case String.trim(hostname) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_hostname(_), do: nil

  @doc false
  def duplicate_device_conflict?(errors) when is_list(errors) do
    Enum.any?(errors, &duplicate_device_conflict?/1)
  end

  def duplicate_device_conflict?(%Ash.Error.Invalid{errors: errors}),
    do: duplicate_device_conflict?(errors)

  def duplicate_device_conflict?(%Ash.Error.Unknown{errors: errors}),
    do: duplicate_device_conflict?(errors)

  def duplicate_device_conflict?(%Postgrex.Error{postgres: postgres}) when is_map(postgres) do
    postgres[:code] == :unique_violation and
      postgres[:constraint] in [@active_ip_unique_constraint, "ocsf_devices_unique_uid_index"]
  end

  def duplicate_device_conflict?(%Ecto.ConstraintError{} = error) do
    duplicate_device_message?(Exception.message(error))
  end

  def duplicate_device_conflict?(%{error: nested}) when not is_nil(nested),
    do: duplicate_device_conflict?(nested)

  def duplicate_device_conflict?(%{field: field} = error) do
    field in [:uid, :ip] or duplicate_device_message?(error_message(error))
  end

  def duplicate_device_conflict?(error) do
    duplicate_device_message?(error_message(error))
  end

  defp duplicate_device_message?(message) when is_binary(message) do
    String.contains?(message, @active_ip_unique_constraint) or
      String.contains?(message, "ocsf_devices_unique_uid_index") or
      String.contains?(message, "has already been taken")
  end

  defp duplicate_device_message?(_message), do: false

  defp error_message(message) when is_binary(message), do: message

  defp error_message(%{__struct__: module} = error) do
    if function_exported?(module, :exception, 1) do
      Exception.message(error)
    else
      inspect(error)
    end
  rescue
    _ -> inspect(error)
  end

  defp error_message(error), do: inspect(error)

  defp extract_ip(result) do
    result["host_ip"]
  end

  @doc false
  def build_host_results(results, execution_id, device_map, context \\ []) do
    agent_id = context[:agent_id]
    sweep_group_id = context[:sweep_group_id]

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
          build_host_record(
            result,
            execution_id,
            ip,
            status,
            device_id,
            {agent_id, sweep_group_id}
          )

        updated_stats = update_host_stats(stats, is_available)

        {[record | acc], updated_stats}
      end)

    {Enum.reverse(records), stats}
  end

  defp result_available?(result) do
    result["available"] == true || icmp_available?(result) || tcp_available?(result)
  end

  defp icmp_available?(result) do
    case result_icmp_status(result) do
      status when is_map(status) -> status["available"] == true
      _ -> result["icmp_available"] == true || result["icmpAvailable"] == true
    end
  end

  defp result_icmp_status(result), do: result["icmp_status"] || result["icmpStatus"]

  defp tcp_available?(result), do: open_ports(result) != []

  defp host_status(_result, true), do: :available
  defp host_status(result, false), do: if(result["error"], do: :error, else: :unavailable)

  defp device_id_for_ip(device_map, ip) do
    case Map.get(device_map, ip) do
      nil -> nil
      device_record -> device_record.canonical_device_id
    end
  end

  defp build_host_record(result, execution_id, ip, status, device_id, {agent_id, sweep_group_id}) do
    # DB connection's search_path determines the schema
    %{
      id: Ash.UUID.generate(),
      execution_id: execution_id,
      ip: ip,
      hostname: result["hostname"],
      status: status,
      response_time_ms: response_time_ms(result),
      open_ports: open_ports(result),
      scanned_ports: PortCoverage.scanned_ports(result),
      sweep_modes_results: build_modes_results(result),
      device_id: device_id,
      agent_id: agent_id,
      sweep_group_id: sweep_group_id,
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
      case port_results(result) do
        nil ->
          []

        port_results when is_list(port_results) ->
          port_results
          |> Enum.filter(fn pr -> pr["available"] == true end)
          |> Enum.map(fn pr -> pr["port"] end)

        _ ->
          []
      end

    ports_from_tcp_open_fields = tcp_open_ports(result)

    (ports_from_port_results ++ ports_from_tcp_open_fields)
    |> Enum.map(&parse_integer/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.filter(&valid_port?/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp port_results(result) do
    result["port_results"] || result["port_scan_results"] || result["portScanResults"]
  end

  defp tcp_open_ports(result) do
    case result["tcp_ports_open"] || result["tcpPortsOpen"] do
      ports when is_list(ports) -> ports
      _ -> []
    end
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
    modes =
      case requested_sweep_modes(result) do
        [] -> observed_sweep_modes(result)
        requested -> requested
      end

    Enum.reduce(modes, %{}, fn mode, acc ->
      {key, status} = sweep_mode_result(result, mode)
      Map.put(acc, key, status)
    end)
  end

  defp requested_sweep_modes(result) do
    result
    |> sweep_modes()
    |> Enum.map(&normalize_sweep_mode/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp sweep_modes(result) do
    case result["sweep_modes"] || result["sweepModes"] do
      modes when is_list(modes) -> modes
      _ -> []
    end
  end

  defp normalize_sweep_mode(mode) when mode in ["icmp", :icmp], do: "icmp"

  defp normalize_sweep_mode(mode) when mode in ["tcp", :tcp, "tcp_connect", :tcp_connect],
    do: "tcp"

  defp normalize_sweep_mode(_mode), do: nil

  defp observed_sweep_modes(result) do
    []
    |> maybe_observed_mode("icmp", icmp_observed?(result))
    |> maybe_observed_mode("tcp", tcp_observed?(result))
  end

  defp maybe_observed_mode(modes, mode, true), do: modes ++ [mode]
  defp maybe_observed_mode(modes, _mode, false), do: modes

  defp icmp_observed?(result) do
    is_map(result_icmp_status(result)) or Map.has_key?(result, "icmp_available") or
      Map.has_key?(result, "icmpAvailable") or legacy_icmp_success?(result)
  end

  defp tcp_observed?(result) do
    case port_results(result) do
      ports when is_list(ports) and ports != [] ->
        true

      _ ->
        has_tcp_open_ports_field?(result) or open_ports(result) != []
    end
  end

  defp has_tcp_open_ports_field?(result) do
    Map.has_key?(result, "tcp_ports_open") or Map.has_key?(result, "tcpPortsOpen")
  end

  defp sweep_mode_result(result, "icmp") do
    icmp_status = result_icmp_status(result)

    status =
      cond do
        icmp_available?(result) -> "success"
        is_map(icmp_status) -> "failed"
        legacy_icmp_success?(result) -> "success"
        true -> "no_response"
      end

    {"icmp", status}
  end

  defp sweep_mode_result(result, "tcp") do
    status = if Enum.empty?(open_ports(result)), do: "no_response", else: "success"

    {"tcp", status}
  end

  defp legacy_icmp_success?(result) do
    result_available?(result) and response_time_ms(result) != nil and
      Enum.empty?(open_ports(result))
  end

  @doc false
  def bulk_insert_host_results([]), do: :ok

  @doc false
  def bulk_insert_host_results(records) do
    # DB connection's search_path determines the schema
    # Insert records with ON CONFLICT handling that preserves non-zero response_time_ms
    #
    # The response_time_ms preservation uses: COALESCE(NULLIF(EXCLUDED.response_time_ms, 0), existing)
    # - If new value is 0: NULLIF returns NULL, COALESCE falls back to existing
    # - If new value is non-zero: NULLIF returns it, COALESCE uses the new value
    # - This prevents sweep results with 0ms from overwriting valid response times
    #
    # scanned_ports accumulates across progress batches: a port attempted in an
    # earlier batch was still attempted, even if this batch's payload didn't
    # cover it. open_ports keeps replace semantics: a port that closed between
    # batches must stop being open. agent_id/sweep_group_id use COALESCE so a
    # later batch lacking reporter context cannot null out identity that an
    # earlier batch established.
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
            scanned_ports:
              fragment(
                "ARRAY(SELECT DISTINCT u FROM unnest(COALESCE(?, '{}'::bigint[]) || COALESCE(EXCLUDED.scanned_ports, '{}'::bigint[])) AS u ORDER BY u)",
                r.scanned_ports
              ),
            sweep_modes_results: fragment("EXCLUDED.sweep_modes_results"),
            device_id: fragment("EXCLUDED.device_id"),
            agent_id: fragment("COALESCE(EXCLUDED.agent_id, ?)", r.agent_id),
            sweep_group_id: fragment("COALESCE(EXCLUDED.sweep_group_id, ?)", r.sweep_group_id),
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

  defp update_device_availability(results, device_map, execution_id, reporter_context, actor) do
    availability_timestamp = utc_now_usec()
    status_timestamp = DateTime.truncate(availability_timestamp, :second)
    availability_policy = availability_policy(reporter_context)

    accepted_observations =
      upsert_agent_availability(
        results,
        device_map,
        execution_id,
        reporter_context,
        availability_timestamp
      )

    available_uids = observation_uids_for_status(accepted_observations, true)
    unavailable_uids = observation_uids_for_status(accepted_observations, false)

    changed_uids =
      canonical_authorized_observation_uids(
        Enum.uniq(available_uids ++ unavailable_uids),
        availability_policy
      )

    if changed_uids != [] do
      changed_uid_set = MapSet.new(changed_uids)
      available_uids = Enum.filter(available_uids, &MapSet.member?(changed_uid_set, &1))
      unavailable_uids = Enum.filter(unavailable_uids, &MapSet.member?(changed_uid_set, &1))

      restore_deleted_devices(changed_uids, actor)

      recovered_rows =
        update_device_statuses_available(
          available_uids,
          status_timestamp,
          availability_policy
        )

      down_rows =
        update_device_statuses_with_hysteresis(
          unavailable_uids,
          status_timestamp,
          reporter_context.group,
          availability_policy
        )

      maybe_emit_availability_events(
        recovered_rows ++ down_rows,
        reporter_context.group,
        reporter_context.reporter_agent_id,
        execution_id
      )

      maybe_add_sweep_source(changed_uids)
    end

    :ok
  end

  defp upsert_agent_availability(
         _results,
         _device_map,
         _execution_id,
         %{reporter_agent_id: agent_id},
         _timestamp
       )
       when agent_id in [nil, ""] do
    []
  end

  defp upsert_agent_availability(results, device_map, execution_id, reporter_context, timestamp) do
    agent_id = reporter_context.reporter_agent_id
    agent_name = agent_display_name(agent_id)

    records =
      results
      |> Enum.map(
        &build_agent_availability_record(
          &1,
          device_map,
          execution_id,
          reporter_context,
          agent_name,
          timestamp
        )
      )
      |> Enum.reject(&is_nil/1)

    bulk_upsert_agent_availability(records)
  end

  defp build_agent_availability_record(
         result,
         device_map,
         execution_id,
         reporter_context,
         agent_name,
         fallback_timestamp
       ) do
    ip = extract_ip(result)
    device_uid = device_id_for_ip(device_map, ip)

    if is_nil(device_uid) do
      nil
    else
      now = utc_now_usec()

      %{
        id: Ash.UUID.generate(),
        device_uid: device_uid,
        agent_id: reporter_context.reporter_agent_id,
        agent_name: agent_name,
        is_available: result_available?(result),
        checked_at: result_checked_at(result, fallback_timestamp),
        response_time_ms: response_time_ms(result),
        open_ports: open_ports(result),
        sweep_modes_results: build_modes_results(result),
        sweep_group_id: reporter_context.resolved_group_id,
        execution_id: valid_uuid_or_nil(execution_id),
        metadata: result_metadata(result, reporter_context),
        inserted_at: now,
        updated_at: now
      }
    end
  end

  defp bulk_upsert_agent_availability([]), do: []

  defp bulk_upsert_agent_availability(records) do
    records = dedupe_availability_records(records)

    on_conflict_query =
      from(a in DeviceAgentAvailability,
        where: fragment("EXCLUDED.checked_at >= ?", a.checked_at),
        update: [
          set: [
            agent_name: fragment("EXCLUDED.agent_name"),
            is_available: fragment("EXCLUDED.is_available"),
            checked_at: fragment("EXCLUDED.checked_at"),
            response_time_ms: fragment("EXCLUDED.response_time_ms"),
            open_ports: fragment("EXCLUDED.open_ports"),
            sweep_modes_results: fragment("EXCLUDED.sweep_modes_results"),
            sweep_group_id: fragment("EXCLUDED.sweep_group_id"),
            execution_id: fragment("EXCLUDED.execution_id"),
            metadata: fragment("EXCLUDED.metadata"),
            updated_at: fragment("EXCLUDED.updated_at")
          ]
        ]
      )

    {count, accepted_observations} =
      Repo.insert_all(
        DeviceAgentAvailability,
        records,
        on_conflict: on_conflict_query,
        conflict_target: [:device_uid, :agent_id],
        returning: [:device_uid, :is_available]
      )

    Logger.debug("SweepResultsIngestor: Upserted #{count} per-agent availability rows")

    # Fire-and-forget: always returns :ok, so ingestion never fails because a
    # composite check refresh could not be scheduled.
    ServiceRadar.CompositeChecks.Refresh.enqueue_many(
      Enum.map(accepted_observations, & &1.device_uid)
    )

    accepted_observations
  rescue
    e ->
      Logger.error("SweepResultsIngestor: Failed to upsert per-agent availability: #{inspect(e)}")
      []
  end

  # One sweep batch can carry multiple results for the same (device_uid,
  # agent_id) — e.g. two swept IPs aliasing to one device. Postgres rejects
  # ON CONFLICT DO UPDATE batches that touch the same row twice
  # (cardinality_violation), so keep only the freshest row per key.
  @doc false
  def dedupe_availability_records(records) do
    records
    |> Enum.group_by(fn record -> {record.device_uid, record.agent_id} end)
    |> Enum.map(fn {_key, rows} -> Enum.max_by(rows, & &1.checked_at, DateTime) end)
  end

  defp agent_display_name(agent_id) do
    Repo.one(from(a in Agent, where: a.uid == ^agent_id, select: coalesce(a.name, a.uid)))
  rescue
    _ -> nil
  end

  defp result_checked_at(result, fallback_timestamp) do
    case result["last_sweep_time"] || result["lastSweepTime"] do
      value when is_binary(value) ->
        case DateTime.from_iso8601(value) do
          {:ok, parsed, _offset} -> to_usec_precision(parsed)
          _ -> to_usec_precision(fallback_timestamp)
        end

      _ ->
        to_usec_precision(fallback_timestamp)
    end
  end

  defp utc_now_usec do
    to_usec_precision(DateTime.utc_now())
  end

  defp to_usec_precision(%DateTime{microsecond: {microsecond, _precision}} = datetime) do
    %{datetime | microsecond: {microsecond, 6}}
  end

  defp result_metadata(result, reporter_context) do
    %{}
    |> maybe_put_string("hostname", normalize_hostname(result["hostname"]))
    |> maybe_put_string("error", result["error"])
    |> Map.put("sweep_reporter_expectation", Atom.to_string(reporter_context.expectation))
    |> maybe_put_string("sweep_resolved_group_id", reporter_context.resolved_group_id)
    |> maybe_put_reported_agent_id(reporter_context)
  end

  defp maybe_put_reported_agent_id(metadata, %{
         authenticated_agent_id: authenticated_agent_id,
         reported_agent_id: reported_agent_id
       })
       when is_binary(authenticated_agent_id) and is_binary(reported_agent_id) and
              authenticated_agent_id != reported_agent_id do
    Map.put(metadata, "sweep_reported_agent_id", reported_agent_id)
  end

  defp maybe_put_reported_agent_id(metadata, _reporter_context), do: metadata

  defp maybe_put_string(map, _key, value) when value in [nil, ""], do: map
  defp maybe_put_string(map, key, value), do: Map.put(map, key, value)

  defp valid_uuid_or_nil(value) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> uuid
      :error -> nil
    end
  end

  defp valid_uuid_or_nil(_value), do: nil

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

  defp observation_uids_for_status(observations, desired) do
    observations
    |> Enum.filter(&(&1.is_available == desired))
    |> Enum.map(& &1.device_uid)
    |> Enum.uniq()
  end

  defp availability_policy(reporter_context) do
    %{
      authenticated_agent_id: reporter_context.authenticated_agent_id,
      reporter_expectation: reporter_context.expectation
    }
  end

  defp expected_reporter?(%{authenticated_agent_id: agent_id, expectation: :expected})
       when is_binary(agent_id), do: true

  defp expected_reporter?(_reporter_context), do: false

  defp canonical_authorized_observation_uids([], _availability_policy), do: []

  defp canonical_authorized_observation_uids(_device_uids, %{reporter_expectation: :unknown}),
    do: []

  defp canonical_authorized_observation_uids(device_uids, availability_policy) do
    sql = """
    SELECT d.uid
    FROM ocsf_devices AS d
    WHERE d.uid = ANY($1)
      AND (
        (
          NULLIF(BTRIM(d.availability_source_agent_id), '') IS NOT NULL
          AND d.availability_source_agent_id = $2
          AND $3::text <> 'unknown'
        )
        OR (
          NULLIF(BTRIM(d.availability_source_agent_id), '') IS NULL
          AND $3::text = 'expected'
        )
      )
    """

    case Repo.query(sql, [
           device_uids,
           availability_policy.authenticated_agent_id,
           Atom.to_string(availability_policy.reporter_expectation)
         ]) do
      {:ok, %{rows: rows}} ->
        Enum.map(rows, fn [uid] -> uid end)

      {:error, reason} ->
        Logger.error(
          "SweepResultsIngestor: Failed to resolve canonical availability authority: #{inspect(reason)}"
        )

        []
    end
  end

  # Mark devices as available and reset consecutive failure count
  defp update_device_statuses_available([], _timestamp, _availability_policy), do: []

  defp update_device_statuses_available(device_uids, timestamp, availability_policy) do
    # DB connection's search_path determines the schema
    # Reset consecutive failure count to 0 when device becomes available
    sql = """
    UPDATE ocsf_devices AS d
    SET
      is_available = true,
      last_seen_time = $2::timestamptz,
      modified_time = $2::timestamptz,
      metadata = jsonb_set(
        jsonb_set(
          COALESCE(d.metadata, '{}'::jsonb),
          '{sweep_consecutive_failures}',
          '0'
        ),
        '{sweep_last_available_at}',
        to_jsonb($2::timestamptz)
      )
    FROM (
      SELECT uid, is_available AS was_available, hostname, ip
      FROM ocsf_devices
      WHERE uid = ANY($1)
    ) old
    WHERE d.uid = old.uid
      AND (
        (
          NULLIF(BTRIM(d.availability_source_agent_id), '') IS NOT NULL
          AND d.availability_source_agent_id = $3
          AND $4::text <> 'unknown'
        )
        OR (
          NULLIF(BTRIM(d.availability_source_agent_id), '') IS NULL
          AND $4::text = 'expected'
        )
      )
    RETURNING d.uid, old.was_available, d.is_available, old.hostname, old.ip
    """

    case Repo.query(sql, [
           device_uids,
           timestamp,
           availability_policy.authenticated_agent_id,
           Atom.to_string(availability_policy.reporter_expectation)
         ]) do
      {:ok, %{num_rows: count, rows: rows}} ->
        Logger.debug(
          "SweepResultsIngestor: Marked #{count} devices as available (reset failure count)"
        )

        rows

      {:error, reason} ->
        Logger.error("SweepResultsIngestor: Failed to mark devices available: #{inspect(reason)}")
        []
    end
  end

  # Default window for "available wins" when sweep interval cannot be determined
  @default_available_wins_window_seconds 60

  # Apply hysteresis for unavailable devices
  # Only marks device as unavailable after threshold consecutive failures
  # "Available wins" - skips devices recently marked available by another sweep
  defp update_device_statuses_with_hysteresis([], _timestamp, _group, _availability_policy),
    do: []

  defp update_device_statuses_with_hysteresis(device_uids, timestamp, group, availability_policy) do
    # DB connection's search_path determines the schema
    #
    # Hysteresis logic using metadata.sweep_consecutive_failures:
    # 1. Increment failure count
    # 2. Only set is_available=false if failure count >= threshold
    #
    # "Available wins" logic:
    # - Skip devices that are currently available from a recent successful sweep
    # - The window is based on the sweep interval (from sweep group config)
    # - This prevents multi-agent conflicts where one agent sees the device
    #   and another doesn't, causing availability flapping
    # - Do not use last_seen_time here: inventory integrations can refresh it
    #   independently and would otherwise keep failed sweep targets online forever.
    #
    # This prevents transient network issues from causing availability flapping
    available_wins_window = get_available_wins_window(group)

    available_wins_cutoff = DateTime.add(timestamp, -available_wins_window, :second)

    sql = """
    UPDATE ocsf_devices AS d
    SET
      metadata = jsonb_set(
        COALESCE(d.metadata, '{}'::jsonb),
        '{sweep_consecutive_failures}',
        to_jsonb(COALESCE((d.metadata->>'sweep_consecutive_failures')::int, 0) + 1)
      ),
      is_available = CASE
        WHEN COALESCE((d.metadata->>'sweep_consecutive_failures')::int, 0) + 1 >= $2
        THEN false
        ELSE d.is_available
      END,
      modified_time = $3
    FROM (
      SELECT uid, is_available AS was_available, hostname, ip
      FROM ocsf_devices
      WHERE uid = ANY($1)
    ) old
    WHERE d.uid = old.uid
      -- "Available wins" - skip devices recently marked available by another sweep
      -- This prevents multi-agent flapping when one agent can reach device and another can't
      AND NOT (
        d.is_available = true
        AND COALESCE((d.metadata->>'sweep_last_available_at')::timestamptz > $4, false)
      )
      AND NOT EXISTS (
        SELECT 1
        FROM device_agent_availability daa
        WHERE daa.device_uid = d.uid
          AND daa.is_available = true
          AND daa.checked_at > $4
          AND (
            (
              NULLIF(BTRIM(d.availability_source_agent_id), '') IS NOT NULL
              AND daa.agent_id = d.availability_source_agent_id
              AND COALESCE(daa.metadata->>'sweep_reporter_expectation', 'legacy') <> 'unknown'
            )
            OR (
              NULLIF(BTRIM(d.availability_source_agent_id), '') IS NULL
              AND COALESCE(daa.metadata->>'sweep_reporter_expectation', 'legacy')
                NOT IN ('unexpected', 'unknown')
            )
          )
      )
      AND (
        (
          NULLIF(BTRIM(d.availability_source_agent_id), '') IS NOT NULL
          AND d.availability_source_agent_id = $5
          AND $6::text <> 'unknown'
        )
        OR (
          NULLIF(BTRIM(d.availability_source_agent_id), '') IS NULL
          AND $6::text = 'expected'
        )
      )
    RETURNING d.uid, old.was_available, d.is_available, old.hostname, old.ip
    """

    case Repo.query(sql, [
           device_uids,
           @unavailable_threshold,
           timestamp,
           available_wins_cutoff,
           availability_policy.authenticated_agent_id,
           Atom.to_string(availability_policy.reporter_expectation)
         ]) do
      {:ok, %{num_rows: count, rows: rows}} ->
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

        rows

      {:error, reason} ->
        Logger.error("SweepResultsIngestor: Failed to apply hysteresis: #{inspect(reason)}")
        []
    end
  end

  defp maybe_emit_availability_events(rows, group, agent_id, execution_id) do
    case availability_event_context(group, agent_id, execution_id) do
      nil ->
        :ok

      context ->
        rows
        |> AvailabilityEvents.transitions_from_rows()
        |> AvailabilityEvents.emit(context)
    end
  end

  defp availability_event_context(
         %SweepGroup{emit_availability_events: true} = group,
         agent_id,
         execution_id
       ) do
    %{
      sweep_group_id: group.id,
      sweep_group_name: group.name,
      agent_id: agent_id,
      execution_id: execution_id
    }
  end

  defp availability_event_context(_group, _agent_id, _execution_id), do: nil

  # Get the "available wins" window based on the sweep group's configured interval
  defp get_available_wins_window(%SweepGroup{interval: interval}) when is_binary(interval),
    do: SweepMonitorWorker.parse_interval_to_seconds(interval)

  defp get_available_wins_window(_group), do: @default_available_wins_window_seconds

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

  defp update_execution(execution_id, sweep_group_id, stats, scanner_metrics, actor, opts) do
    expected_total_hosts = Keyword.get(opts, :expected_total_hosts)
    is_final = Keyword.get(opts, :is_final, true)
    banner_grab_summary = Keyword.get(opts, :banner_grab_summary)
    request_id = Keyword.get(opts, :request_id)
    reporter_context = Keyword.fetch!(opts, :reporter_context)

    {completed_at, updated_at} = execution_timestamps(is_final)
    duration_ms = execution_duration_ms(execution_id, is_final, completed_at)
    inc_fields = execution_inc_fields(stats, expected_total_hosts)

    set_fields =
      updated_at
      |> execution_set_fields(scanner_metrics)
      |> maybe_mark_execution_complete(is_final, completed_at, duration_ms)

    update_execution_row(execution_id, inc_fields, set_fields)
    maybe_set_expected_total(execution_id, expected_total_hosts, updated_at)

    if is_final do
      record_group_execution(reporter_context, actor)
    end

    maybe_record_banner_grab_phase(
      execution_id,
      sweep_group_id,
      banner_grab_summary,
      request_id,
      actor,
      is_final
    )

    fetch_execution(execution_id)
  end

  defp maybe_record_banner_grab_phase(
         _execution_id,
         _sweep_group_id,
         _summary,
         _request_id,
         _actor,
         false
       ), do: :ok

  defp maybe_record_banner_grab_phase(
         _execution_id,
         _sweep_group_id,
         nil,
         _request_id,
         _actor,
         true
       ), do: :ok

  defp maybe_record_banner_grab_phase(
         _execution_id,
         _sweep_group_id,
         summary,
         _request_id,
         _actor,
         true
       )
       when summary == %{}, do: :ok

  defp maybe_record_banner_grab_phase(
         execution_id,
         sweep_group_id,
         summary,
         request_id,
         actor,
         true
       ) do
    audited_summary = banner_grab_audit_summary(summary)
    audit_context = audit_context(sweep_group_id, request_id)
    audit_actor = audit_actor(actor, request_id)

    case Ash.get(SweepGroupExecution, execution_id, actor: audit_actor) do
      {:ok, execution} ->
        execution
        |> Ash.Changeset.for_update(
          :record_banner_grab_phase,
          %{banner_grab_summary: audited_summary},
          actor: audit_actor
        )
        |> Ash.Changeset.set_context(audit_context)
        |> Ash.update(actor: audit_actor)
        |> case do
          {:ok, _updated} ->
            :ok

          {:error, reason} ->
            record_banner_grab_audit_failure(
              :update_failed,
              execution_id,
              sweep_group_id,
              reason
            )

            :ok
        end

      {:error, reason} ->
        record_banner_grab_audit_failure(
          :load_failed,
          execution_id,
          sweep_group_id,
          reason
        )

        :ok
    end
  end

  defp audit_context(sweep_group_id, request_id) do
    %{}
    |> maybe_put_context(:sweep_group_id, sweep_group_id)
    |> maybe_put_context(:request_id, request_id)
  end

  defp maybe_put_context(context, _key, nil), do: context
  defp maybe_put_context(context, _key, ""), do: context
  defp maybe_put_context(context, key, value), do: Map.put(context, key, value)

  defp audit_actor(%{} = actor, request_id) when is_binary(request_id) and request_id != "",
    do: Map.put(actor, :request_id, request_id)

  defp audit_actor(actor, _request_id), do: actor

  @doc false
  def banner_grab_audit_summary(summary) when is_map(summary) do
    %{
      "probe_count" => counter(summary, "sweep_banner_grab_probes_total"),
      "banner_match_count" => counter(summary, "sweep_banner_grab_matches_total"),
      "empty_response_count" => counter(summary, "sweep_banner_grab_empty_response_total"),
      "error_count" => banner_grab_error_count(summary),
      "total_bytes_received" => counter(summary, "sweep_banner_grab_bytes_received_total"),
      "counters" => sanitize_banner_grab_counters(summary)
    }
  end

  # Filter the agent-supplied summary down to allowlisted keys, validating each
  # value against its expected type. Mismatched values are dropped (not coerced)
  # so that the persisted audit row never contains attacker-controlled blobs,
  # and a telemetry event is emitted per dropped key for observability.
  defp sanitize_banner_grab_counters(summary) do
    Enum.reduce(@banner_grab_counter_keys, %{}, fn {key, type}, acc ->
      case Map.fetch(summary, key) do
        :error ->
          acc

        {:ok, value} ->
          if valid_counter_value?(value, type) do
            Map.put(acc, key, value)
          else
            emit_counter_dropped(key, type, value)
            acc
          end
      end
    end)
  end

  defp valid_counter_value?(value, :non_neg_integer) when is_integer(value) and value >= 0,
    do: true

  defp valid_counter_value?(_value, _type), do: false

  defp emit_counter_dropped(key, expected_type, value) do
    :telemetry.execute(
      @banner_grab_counter_dropped_event,
      %{count: 1, banner_grab_counter_dropped_total: 1},
      %{
        counter_key: key,
        expected_type: expected_type,
        value_type: counter_value_type(value)
      }
    )
  end

  defp counter_value_type(value) when is_integer(value), do: :integer
  defp counter_value_type(value) when is_float(value), do: :float
  defp counter_value_type(value) when is_binary(value), do: :binary
  defp counter_value_type(value) when is_map(value), do: :map
  defp counter_value_type(value) when is_list(value), do: :list
  defp counter_value_type(value) when is_atom(value), do: :atom
  defp counter_value_type(_value), do: :other

  @doc false
  def record_banner_grab_audit_failure(operation, execution_id, sweep_group_id, reason) do
    reason_text = inspect(reason)

    Logger.error("SweepResultsIngestor: failed to record banner-grab audit summary",
      operation: operation,
      execution_id: execution_id,
      sweep_group_id: sweep_group_id,
      reason: reason_text
    )

    :telemetry.execute(
      @banner_grab_audit_failed_event,
      %{count: 1, banner_grab_audit_failed_total: 1},
      %{
        operation: operation,
        execution_id: to_string(execution_id),
        sweep_group_id: to_string(sweep_group_id),
        reason: reason_text
      }
    )
  end

  defp banner_grab_error_count(summary) do
    counter(summary, "sweep_banner_grab_errors_total") +
      counter(summary, "sweep_banner_grab_connection_reset_total") +
      counter(summary, "sweep_banner_grab_timeout_total")
  end

  defp counter(summary, key) do
    case Map.get(summary, key) do
      value when is_integer(value) and value >= 0 -> value
      value when is_float(value) and value >= 0 -> trunc(value)
      value when is_binary(value) -> parse_counter(value)
      _ -> 0
    end
  end

  defp parse_counter(value) do
    case Integer.parse(value) do
      {parsed, ""} when parsed >= 0 -> parsed
      _ -> 0
    end
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
          hosts_failed: e.hosts_failed,
          banner_grab_summary: e.banner_grab_summary
        }
      )
    )
  end

  defp ensure_execution_exists(
         execution_id,
         reporter_context,
         config_version,
         expected_total_hosts,
         actor
       ) do
    cond do
      not is_nil(reporter_context.execution) ->
        with :ok <- validate_execution_owner(reporter_context.execution, reporter_context) do
          Logger.debug("SweepResultsIngestor: Execution #{execution_id} already exists")
          :ok
        end

      is_nil(reporter_context.resolved_group_id) ->
        Logger.warning(
          "SweepResultsIngestor: Cannot create execution - no sweep_group_id provided"
        )

        {:error, :missing_sweep_group_id}

      is_nil(reporter_context.group) ->
        {:error, :unresolved_sweep_group}

      is_nil(reporter_context.authenticated_agent_id) ->
        {:error, :conflicting_execution_reporter}

      true ->
        create_execution(
          execution_id,
          reporter_context,
          config_version,
          expected_total_hosts,
          actor
        )
    end
  end

  defp create_execution(
         execution_id,
         reporter_context,
         config_version,
         expected_total_hosts,
         actor
       ) do
    now = DateTime.utc_now()
    started_at = DateTime.truncate(now, :second)
    inserted_at = DateTime.truncate(now, :microsecond)
    hosts_total = expected_total_hosts || 0
    sweep_group_id = reporter_context.resolved_group_id
    agent_id = reporter_context.authenticated_agent_id

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

    {inserted_count, _} =
      Repo.insert_all(
        SweepGroupExecution,
        [record],
        on_conflict: :nothing,
        returning: false
      )

    with {:ok, winning_execution} <- load_execution_identity(execution_id),
         :ok <-
           validate_inserted_or_winning_execution_owner(
             inserted_count,
             winning_execution,
             reporter_context
           ) do
      maybe_mark_superseded_executions(
        reporter_context,
        execution_id,
        started_at
      )

      case inserted_count do
        1 ->
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
          record_group_execution(reporter_context, actor)

          :ok

        0 ->
          Logger.debug("SweepResultsIngestor: Execution #{execution_id} already exists (race)")
          :ok
      end
    end
  rescue
    e ->
      Logger.error("SweepResultsIngestor: Failed to create execution: #{inspect(e)}")
      {:error, e}
  end

  defp record_group_execution(%{expectation: :expected, group: %SweepGroup{} = group}, actor) do
    group
    |> Ash.Changeset.for_update(:record_execution, %{}, actor: actor)
    |> Ash.update(actor: actor)
    |> case do
      {:ok, _updated} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "SweepResultsIngestor: failed to record last_run_at for group #{group.id}: #{inspect(reason)}"
        )

        :ok
    end
  end

  defp record_group_execution(_reporter_context, _actor), do: :ok

  defp validate_execution_owner(nil, _reporter_context),
    do: {:error, :unresolved_execution_identity}

  defp validate_execution_owner(execution, reporter_context) do
    authenticated_agent_id = valid_reporter_uid(reporter_context.authenticated_agent_id)

    cond do
      execution.sweep_group_id != reporter_context.resolved_group_id ->
        {:error, :conflicting_execution_group}

      is_nil(authenticated_agent_id) ->
        {:error, :conflicting_execution_reporter}

      valid_reporter_uid(execution.agent_id) != authenticated_agent_id ->
        {:error, :conflicting_execution_reporter}

      true ->
        :ok
    end
  end

  defp validate_inserted_or_winning_execution_owner(0, winning_execution, reporter_context) do
    validate_execution_owner(winning_execution, reporter_context)
  end

  defp validate_inserted_or_winning_execution_owner(1, nil, _reporter_context),
    do: {:error, :unresolved_execution_identity}

  defp validate_inserted_or_winning_execution_owner(1, inserted_execution, reporter_context) do
    validate_execution_owner(inserted_execution, reporter_context)
  end

  defp maybe_mark_superseded_executions(
         %{authenticated_agent_id: agent_id, expectation: expectation} = reporter_context,
         execution_id,
         now
       )
       when is_binary(agent_id) and expectation in [:expected, :unexpected] do
    mark_superseded_executions(
      reporter_context.resolved_group_id,
      agent_id,
      execution_id,
      now
    )
  end

  defp maybe_mark_superseded_executions(_reporter_context, _execution_id, _now), do: :ok

  defp mark_superseded_executions(nil, _agent_id, _execution_id, _now), do: :ok
  defp mark_superseded_executions("", _agent_id, _execution_id, _now), do: :ok

  defp mark_superseded_executions(sweep_group_id, agent_id, execution_id, now) do
    base_query =
      from(e in SweepGroupExecution,
        where:
          e.sweep_group_id == ^sweep_group_id and e.status == :running and
            e.id != ^execution_id
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
      hosts_total: Map.get(stats1, :hosts_total, 0) + Map.get(stats2, :hosts_total, 0),
      hosts_available:
        Map.get(stats1, :hosts_available, 0) + Map.get(stats2, :hosts_available, 0),
      hosts_failed: Map.get(stats1, :hosts_failed, 0) + Map.get(stats2, :hosts_failed, 0),
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
