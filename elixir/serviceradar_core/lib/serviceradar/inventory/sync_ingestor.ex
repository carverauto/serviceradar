defmodule ServiceRadar.Inventory.SyncIngestor do
  @moduledoc """
  Ingests sync device updates and upserts OCSF device records using DIRE.

  Optimized for bulk operations to handle large batches efficiently.
  Uses batch DB queries and bulk upserts instead of one-by-one processing.

  In schema-agnostic mode, operates as a single instance since the DB schema
  is set by CNPG search_path credentials.
  """

  require Logger

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Identity.AliasEvents
  alias ServiceRadar.Identity.DeviceAliasState
  alias ServiceRadar.Inventory.{Device, DeviceIdentifier, IdentityReconciler}
  alias ServiceRadar.Repo

  import Ecto.Query

  # Process in chunks to balance memory vs DB efficiency
  @batch_size 500

  @spec ingest_updates([map()], keyword()) :: :ok | {:error, term()}
  def ingest_updates(updates, opts \\ []) do
    # DB connection's search_path determines the schema
    actor = Keyword.get(opts, :actor, SystemActor.system(:sync_ingestor))

    updates = List.wrap(updates)
    total_count = length(updates)
    batch_concurrency = batch_concurrency()

    Logger.info("SyncIngestor: Processing #{total_count} updates in batches of #{@batch_size}")
    start_time = System.monotonic_time(:millisecond)

    batches =
      updates
      |> Enum.chunk_every(@batch_size)
      |> Enum.with_index(1)

    total_batches = ceil(total_count / @batch_size)

    result =
      batches
      |> Task.async_stream(
        fn {batch, batch_num} ->
          batch_start = System.monotonic_time(:millisecond)
          ingest_batch(batch, actor)
          batch_elapsed = System.monotonic_time(:millisecond) - batch_start

          Logger.debug(
            "SyncIngestor: Batch #{batch_num}/#{total_batches} (#{length(batch)} devices) completed in #{batch_elapsed}ms"
          )

          :ok
        end,
        max_concurrency: batch_concurrency,
        timeout: :infinity,
        ordered: false
      )
      |> Enum.reduce_while(:ok, fn
        {:ok, :ok}, _acc ->
          {:cont, :ok}

        {:ok, {:error, reason}}, _acc ->
          {:halt, {:error, reason}}

        {:exit, reason}, _acc ->
          {:halt, {:error, reason}}
      end)

    elapsed = System.monotonic_time(:millisecond) - start_time
    rate = if elapsed > 0, do: Float.round(total_count / (elapsed / 1000), 1), else: 0
    Logger.info("SyncIngestor: Completed #{total_count} updates in #{elapsed}ms (#{rate} devices/sec)")

    result
  end

  defp ingest_batch(updates, actor) do
    # Step 1: Normalize all updates
    normalized_updates =
      updates
      |> Enum.map(&normalize_update/1)
      |> Enum.map(&enrich_alias_metadata/1)

    # Step 2: Extract all identifiers for bulk lookup
    all_identifiers = extract_all_identifiers(normalized_updates)

    # Step 3: Bulk lookup existing device identifiers
    # DB connection's search_path determines the schema
    existing_mappings = bulk_lookup_identifiers(all_identifiers)

    # Step 4: Bulk lookup existing devices by IP for IP-only devices
    ip_only_updates = Enum.filter(normalized_updates, fn u ->
      ids = IdentityReconciler.extract_strong_identifiers(u)
      not IdentityReconciler.has_strong_identifier?(ids) and ids.ip != ""
    end)
    ip_to_device = bulk_lookup_by_ip(ip_only_updates)

    # Step 5: Resolve device IDs (using cached lookups)
    resolved_updates =
      Enum.map(normalized_updates, fn update ->
        device_id = resolve_device_id_cached(update, existing_mappings, ip_to_device)
        {update, device_id}
      end)

    # Step 6: Build device upsert records
    timestamp = DateTime.utc_now() |> DateTime.truncate(:second)
    device_records = build_device_upsert_records(resolved_updates, timestamp)

    # Step 7: Bulk upsert devices
    device_result =
      if Enum.empty?(device_records) do
        :ok
      else
        bulk_upsert_devices(device_records)
      end

    # Step 8: Bulk upsert device identifiers
    identifier_records = build_identifier_records(resolved_updates)
    identifier_result =
      if Enum.empty?(identifier_records) do
        :ok
      else
        bulk_upsert_identifiers(identifier_records)
      end

    alias_result =
      if device_result == :ok do
        process_alias_updates(resolved_updates, actor)
      else
        :ok
      end

    case {device_result, identifier_result, alias_result} do
      {:ok, :ok, :ok} -> :ok
      {{:error, _} = error, _, _} -> error
      {_, {:error, _} = error, _} -> error
      {_, _, {:error, _} = error} -> error
      _ -> :ok
    end
  end

  # Extract all identifiers from all updates for bulk lookup
  defp extract_all_identifiers(updates) do
    updates
    |> Enum.flat_map(fn update ->
      ids = IdentityReconciler.extract_strong_identifiers(update)
      partition = ids.partition

      []
      |> maybe_add_id(:armis_device_id, ids.armis_id, partition)
      |> maybe_add_id(:integration_id, ids.integration_id, partition)
      |> maybe_add_id(:netbox_device_id, ids.netbox_id, partition)
      |> maybe_add_id(:mac, ids.mac, partition)
    end)
    |> Enum.uniq()
  end

  defp maybe_add_id(acc, _type, nil, _partition), do: acc
  defp maybe_add_id(acc, type, value, partition), do: [{type, value, partition} | acc]

  # Bulk lookup device identifiers - single query for all identifiers
  # DB connection's search_path determines the schema
  defp bulk_lookup_identifiers([]), do: %{}

  defp bulk_lookup_identifiers(identifiers) do
    # Build OR conditions for all identifiers
    conditions = Enum.map(identifiers, fn {type, value, partition} ->
      dynamic(
        [di],
        di.identifier_type == ^to_string(type) and
        di.identifier_value == ^value and
        di.partition == ^partition
      )
    end)

    combined_condition = Enum.reduce(conditions, fn cond, acc ->
      dynamic([di], ^acc or ^cond)
    end)

    query =
      from(di in DeviceIdentifier,
        where: ^combined_condition,
        select: {di.identifier_type, di.identifier_value, di.partition, di.device_id}
      )

    Repo.all(query)
    |> Enum.reduce(%{}, fn {type, value, partition, device_id}, acc ->
      type_atom =
        case type do
          type when is_binary(type) -> String.to_atom(type)
          type when is_atom(type) -> type
          _ -> nil
        end

      if type_atom == nil do
        acc
      else
        key = {type_atom, value, partition}
        Map.put(acc, key, device_id)
      end
    end)
  rescue
    e ->
      Logger.warning("Bulk identifier lookup failed: #{inspect(e)}")
      %{}
  end

  # Bulk lookup devices by IP
  # DB connection's search_path determines the schema
  defp bulk_lookup_by_ip([]), do: %{}

  defp bulk_lookup_by_ip(updates) do
    ips = updates
          |> Enum.map(fn u -> u.ip end)
          |> Enum.filter(&(&1 != nil and &1 != ""))
          |> Enum.uniq()

    if Enum.empty?(ips) do
      %{}
    else
      alias_map = lookup_alias_device_ids_by_ip(ips)
      remaining_ips = ips -- Map.keys(alias_map)

      direct_map =
        if remaining_ips == [] do
          %{}
        else
          query =
            from(d in Device,
              where: d.ip in ^remaining_ips,
              select: {d.ip, d.uid}
            )

          Repo.all(query)
          |> Enum.filter(fn {_ip, uid} -> IdentityReconciler.serviceradar_uuid?(uid) end)
          |> Map.new()
        end

      Map.merge(direct_map, alias_map)
    end
  rescue
    e ->
      Logger.warning("Bulk IP lookup failed: #{inspect(e)}")
      %{}
  end

  defp lookup_alias_device_ids_by_ip([]), do: %{}

  defp lookup_alias_device_ids_by_ip(ips) do
    query =
      from(a in DeviceAliasState,
        where:
          a.alias_type == "ip" and a.alias_value in ^ips and
            a.state in ["confirmed", "updated"],
        select: {a.alias_value, a.device_id}
      )

    Repo.all(query)
    |> Enum.filter(fn {_ip, uid} -> IdentityReconciler.serviceradar_uuid?(uid) end)
    |> Map.new()
  rescue
    e ->
      Logger.warning("Bulk IP alias lookup failed: #{inspect(e)}")
      %{}
  end

  # Resolve device ID using cached lookups
  defp resolve_device_id_cached(update, existing_mappings, ip_to_device) do
    # Skip service component IDs
    if IdentityReconciler.service_device_id?(update.device_id) do
      update.device_id
    else
      ids = IdentityReconciler.extract_strong_identifiers(update)

      cached_device_id(ids, existing_mappings) ||
        existing_device_id(update, ids, ip_to_device) ||
        IdentityReconciler.generate_deterministic_device_id(ids)
    end
  end

  defp cached_device_id(ids, existing_mappings) do
    lookup_cached(:armis_device_id, ids.armis_id, ids.partition, existing_mappings) ||
      lookup_cached(:integration_id, ids.integration_id, ids.partition, existing_mappings) ||
      lookup_cached(:netbox_device_id, ids.netbox_id, ids.partition, existing_mappings) ||
      lookup_cached(:mac, ids.mac, ids.partition, existing_mappings)
  end

  defp existing_device_id(update, ids, ip_to_device) do
    cond do
      IdentityReconciler.serviceradar_uuid?(update.device_id) ->
        update.device_id

      ids.ip != "" and Map.has_key?(ip_to_device, ids.ip) ->
        Map.get(ip_to_device, ids.ip)

      true ->
        nil
    end
  end

  defp lookup_cached(_type, nil, _partition, _mappings), do: nil
  defp lookup_cached(type, value, partition, mappings) do
    Map.get(mappings, {type, value, partition})
  end

  defp build_device_upsert_records(resolved_updates, timestamp) do
    resolved_updates
    |> Enum.reduce(%{}, fn {update, device_id}, acc ->
      source = if update.source in [nil, ""], do: "unknown", else: update.source

      record = %{
        uid: device_id,
        ip: update.ip,
        mac: update.mac,
        hostname: update.hostname,
        name: update.hostname || update.ip,
        is_available: update.is_available || false,
        metadata: update.metadata || %{},
        tags: update.tags || %{},
        discovery_sources: [source],
        first_seen_time: timestamp,
        last_seen_time: timestamp,
        created_time: timestamp,
        modified_time: timestamp
      }

      Map.put(acc, device_id, record)
    end)
    |> Map.values()
  end

  # DB connection's search_path determines the schema
  defp bulk_upsert_devices(records) do
    update_query =
      from(d in Device,
        update: [
          set: [
            ip: fragment("COALESCE(EXCLUDED.ip, ?)", d.ip),
            mac: fragment("COALESCE(EXCLUDED.mac, ?)", d.mac),
            hostname: fragment("COALESCE(EXCLUDED.hostname, ?)", d.hostname),
            name: fragment("COALESCE(EXCLUDED.name, ?)", d.name),
            is_available: fragment("COALESCE(EXCLUDED.is_available, ?)", d.is_available),
            metadata: fragment("COALESCE(EXCLUDED.metadata, ?)", d.metadata),
            discovery_sources:
              fragment(
                "(SELECT array_agg(DISTINCT src) FROM unnest(array_cat(COALESCE(?, ARRAY[]::text[]), EXCLUDED.discovery_sources)) AS src WHERE src IS NOT NULL AND src <> '')",
                d.discovery_sources
              ),
            last_seen_time: fragment("EXCLUDED.last_seen_time"),
            modified_time: fragment("EXCLUDED.modified_time")
          ]
        ]
      )

    Repo.insert_all(
      Device,
      records,
      on_conflict: update_query,
      conflict_target: [:uid]
    )
    :ok
  rescue
    e ->
      Logger.warning("Bulk device upsert failed: #{inspect(e)}")
      {:error, e}
  end

  # Build identifier records for bulk upsert
  defp build_identifier_records(resolved_updates) do
    resolved_updates
    |> Enum.flat_map(fn {update, device_id} ->
      ids = IdentityReconciler.extract_strong_identifiers(update)
      partition = ids.partition

      []
      |> maybe_add_identifier_record(device_id, :armis_device_id, ids.armis_id, partition)
      |> maybe_add_identifier_record(device_id, :integration_id, ids.integration_id, partition)
      |> maybe_add_identifier_record(device_id, :netbox_device_id, ids.netbox_id, partition)
      |> maybe_add_identifier_record(device_id, :mac, ids.mac, partition)
    end)
    |> Enum.uniq_by(fn r -> {r.identifier_type, r.identifier_value, r.partition} end)
  end

  defp maybe_add_identifier_record(acc, _device_id, _type, nil, _partition), do: acc
  defp maybe_add_identifier_record(acc, device_id, type, value, partition) do
    [%{
      device_id: device_id,
      identifier_type: type,
      identifier_value: value,
      partition: partition,
      confidence: :strong,
      source: "sync_ingestor"
    } | acc]
  end

  # Bulk upsert identifiers
  # DB connection's search_path determines the schema
  defp bulk_upsert_identifiers(records) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    insert_records =
      Enum.map(records, fn r ->
        Map.merge(r, %{
          first_seen: now,
          last_seen: now
        })
      end)

    unless Enum.empty?(insert_records) do
      Repo.insert_all(
        DeviceIdentifier,
        insert_records,
        on_conflict: {:replace, [:device_id, :last_seen]},
        conflict_target: [:identifier_type, :identifier_value, :partition]
      )
    end

    :ok
  rescue
    e ->
      Logger.warning("Bulk identifier upsert failed: #{inspect(e)}")
      {:error, e}
  end

  defp normalize_update(update) when is_map(update) do
    %{
      device_id: get_string(update, ["device_id", :device_id]),
      ip: get_string(update, ["ip", :ip]),
      mac: get_string(update, ["mac", :mac]),
      hostname: get_string(update, ["hostname", :hostname]),
      partition: get_string(update, ["partition", :partition]) || "default",
      metadata: get_map(update, ["metadata", :metadata]),
      tags: get_map(update, ["tags", :tags]),
      timestamp: parse_timestamp(get_value(update, ["timestamp", :timestamp])),
      is_available: get_bool(update, ["is_available", :is_available]),
      source: get_string(update, ["source", :source]) || "unknown"
    }
  end

  defp normalize_update(_update) do
    %{
      device_id: nil,
      ip: nil,
      mac: nil,
      hostname: nil,
      partition: "default",
      metadata: %{},
      tags: %{},
      timestamp: nil,
      is_available: false,
      source: "unknown"
    }
  end

  defp batch_concurrency do
    configured =
      Application.get_env(
        :serviceradar_core,
        :sync_ingestor_batch_concurrency,
        System.schedulers_online()
      )

    if is_integer(configured) and configured > 0 do
      configured
    else
      System.schedulers_online()
    end
  end

  defp parse_timestamp(nil), do: nil

  defp parse_timestamp(timestamp) when is_binary(timestamp) do
    case DateTime.from_iso8601(timestamp) do
      {:ok, parsed, _offset} -> parsed
      _ -> nil
    end
  end

  defp parse_timestamp(%DateTime{} = timestamp), do: timestamp

  defp parse_timestamp(_timestamp), do: nil

  defp get_value(map, keys) do
    Enum.find_value(keys, fn key ->
      case map do
        %{^key => value} -> value
        _ -> nil
      end
    end)
  end

  defp get_string(map, keys) do
    case get_value(map, keys) do
      value when is_binary(value) -> String.trim(value)
      _ -> nil
    end
  end

  defp get_map(map, keys) do
    case get_value(map, keys) do
      value when is_map(value) -> value
      _ -> %{}
    end
  end

  defp enrich_alias_metadata(update) do
    metadata = update.metadata || %{}
    alias_ips = alias_ips_from_metadata(metadata)

    if alias_ips == [] do
      update
    else
      timestamp = update.timestamp || DateTime.utc_now()
      timestamp = DateTime.truncate(timestamp, :second)
      ts_string = DateTime.to_iso8601(timestamp)

      alias_ips =
        alias_ips
        |> maybe_add_alias_ip(update.ip)
        |> Enum.uniq()

      metadata =
        metadata
        |> Map.put("_alias_last_seen_at", ts_string)
        |> maybe_put("_alias_last_seen_ip", update.ip)
        |> add_alias_ip_keys(alias_ips, ts_string)

      %{update | metadata: metadata, timestamp: timestamp}
    end
  end

  defp alias_ips_from_metadata(metadata) do
    metadata
    |> Map.keys()
    |> Enum.flat_map(fn key ->
      cond do
        String.starts_with?(key, "ip_alias:") ->
          [String.trim(String.replace_prefix(key, "ip_alias:", ""))]

        String.starts_with?(key, "alt_ip:") ->
          [String.trim(String.replace_prefix(key, "alt_ip:", ""))]

        true ->
          []
      end
    end)
    |> Enum.reject(&(&1 == ""))
  end

  defp maybe_add_alias_ip(ips, nil), do: ips
  defp maybe_add_alias_ip(ips, ""), do: ips
  defp maybe_add_alias_ip(ips, ip), do: ips ++ [ip]

  defp add_alias_ip_keys(metadata, ips, ts_string) do
    Enum.reduce(ips, metadata, fn ip, acc ->
      Map.put(acc, "ip_alias:#{ip}", ts_string)
    end)
  end

  defp maybe_put(metadata, _key, nil), do: metadata
  defp maybe_put(metadata, _key, ""), do: metadata
  defp maybe_put(metadata, key, value), do: Map.put(metadata, key, value)

  defp process_alias_updates(resolved_updates, actor) do
    confirm_threshold =
      Application.get_env(:serviceradar_core, :identity_alias_confirm_threshold, 3)

    updates =
      Enum.map(resolved_updates, fn {update, device_id} ->
        Map.put(update, :device_id, device_id)
      end)

    case AliasEvents.process_and_persist(updates,
           actor: actor,
           confirm_threshold: confirm_threshold
         ) do
      {:ok, _events} ->
        :ok

      other ->
        Logger.warning("Alias state processing failed: #{inspect(other)}")
        {:error, other}
    end
  end

  defp get_bool(map, keys) do
    case get_value(map, keys) do
      true -> true
      _ -> false
    end
  end
end
