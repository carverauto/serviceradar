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

  alias ServiceRadar.Inventory.{
    Device,
    DeviceEnrichmentRules,
    DeviceIdentifier,
    IdentityReconciler
  }

  alias ServiceRadar.Repo

  import Ecto.Query

  # Process in chunks to balance memory vs DB efficiency
  @batch_size 500
  @vendor_tokens [
    {"cisco", "Cisco"},
    {"juniper", "Juniper"},
    {"arista", "Arista"},
    {"mikrotik", "MikroTik"},
    {"fortinet", "Fortinet"},
    {"palo alto", "Palo Alto Networks"},
    {"checkpoint", "Check Point"},
    {"hpe", "HPE"},
    {"hewlett-packard", "HPE"},
    {"hp", "HP"},
    {"dell", "Dell"},
    {"netgear", "Netgear"}
  ]

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

    Logger.info(
      "SyncIngestor: Completed #{total_count} updates in #{elapsed}ms (#{rate} devices/sec)"
    )

    result
  end

  defp ingest_batch(updates, actor) do
    normalized_updates = normalize_updates(updates)

    {resolved_updates, device_records, identifier_records} =
      resolve_updates(normalized_updates, actor)

    device_result = upsert_devices(device_records)
    identifier_result = upsert_identifiers(identifier_records)

    _ = maybe_process_alias_conflicts(device_result, resolved_updates, actor)
    alias_result = maybe_process_alias_updates(device_result, resolved_updates, actor)

    finalize_ingest_results(device_result, identifier_result, alias_result)
  end

  defp normalize_updates(updates) do
    updates
    |> Enum.map(&normalize_update/1)
    |> Enum.map(&enrich_alias_metadata/1)
  end

  defp resolve_updates(normalized_updates, _actor) do
    all_identifiers = extract_all_identifiers(normalized_updates)
    existing_mappings = bulk_lookup_identifiers(all_identifiers)
    existing_ip_to_device = bulk_lookup_by_ip(ip_only_updates(normalized_updates))

    {resolved_updates, _batch_ip_to_device} =
      Enum.reduce(normalized_updates, {[], existing_ip_to_device}, fn update,
                                                                      {acc, ip_to_device} ->
        ids = effective_identifiers(update)

        device_id =
          case ids.ip do
            ip when is_binary(ip) and ip != "" -> Map.get(ip_to_device, ip)
            _ -> nil
          end ||
            resolve_device_id_cached(update, existing_mappings, ip_to_device)

        next_ip_to_device =
          case ids.ip do
            ip when is_binary(ip) and ip != "" -> Map.put(ip_to_device, ip, device_id)
            _ -> ip_to_device
          end

        {[{update, device_id} | acc], next_ip_to_device}
      end)

    resolved_updates = Enum.reverse(resolved_updates)

    timestamp = DateTime.utc_now() |> DateTime.truncate(:second)
    device_records = build_device_upsert_records(resolved_updates, timestamp)
    identifier_records = build_identifier_records(resolved_updates)

    {resolved_updates, device_records, identifier_records}
  end

  defp ip_only_updates(normalized_updates) do
    Enum.filter(normalized_updates, fn update ->
      ids = effective_identifiers(update)
      not IdentityReconciler.has_strong_identifier?(ids) and ids.ip != ""
    end)
  end

  defp upsert_devices([]), do: :ok
  defp upsert_devices(records), do: bulk_upsert_devices(records)

  defp upsert_identifiers([]), do: :ok
  defp upsert_identifiers(records), do: bulk_upsert_identifiers(records)

  defp maybe_process_alias_conflicts(:ok, resolved_updates, actor) do
    process_alias_conflicts(resolved_updates, actor)
  end

  defp maybe_process_alias_conflicts(_result, _resolved_updates, _actor), do: :ok

  defp maybe_process_alias_updates(:ok, resolved_updates, actor) do
    process_alias_updates(resolved_updates, actor)
  end

  defp maybe_process_alias_updates(_result, _resolved_updates, _actor), do: :ok

  defp finalize_ingest_results(device_result, identifier_result, alias_result) do
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
      ids = effective_identifiers(update)
      partition = ids.partition
      include_mac? = include_mac_identifier?(update)

      []
      |> maybe_add_id(:armis_device_id, ids.armis_id, partition)
      |> maybe_add_id(:integration_id, ids.integration_id, partition)
      |> maybe_add_id(:netbox_device_id, ids.netbox_id, partition)
      |> maybe_add_id_if(include_mac?, :mac, ids.mac, partition)
    end)
    |> Enum.uniq()
  end

  defp maybe_add_id(acc, _type, nil, _partition), do: acc
  defp maybe_add_id(acc, type, value, partition), do: [{type, value, partition} | acc]
  defp maybe_add_id_if(acc, false, _type, _value, _partition), do: acc

  defp maybe_add_id_if(acc, true, type, value, partition),
    do: maybe_add_id(acc, type, value, partition)

  # Bulk lookup device identifiers - single query for all identifiers
  # DB connection's search_path determines the schema
  defp bulk_lookup_identifiers([]), do: %{}

  defp bulk_lookup_identifiers(identifiers) do
    # Build OR conditions for all identifiers
    conditions =
      Enum.map(identifiers, fn {type, value, partition} ->
        dynamic(
          [di],
          di.identifier_type == ^to_string(type) and
            di.identifier_value == ^value and
            di.partition == ^partition
        )
      end)

    combined_condition =
      Enum.reduce(conditions, fn cond, acc ->
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
    ips = extract_ips(updates)

    case ips do
      [] ->
        %{}

      _ ->
        alias_map = lookup_alias_device_ids_by_ip(ips)
        direct_map = lookup_devices_by_ip(ips, alias_map)
        Map.merge(direct_map, alias_map)
    end
  rescue
    e ->
      Logger.warning("Bulk IP lookup failed: #{inspect(e)}")
      %{}
  end

  defp extract_ips(updates) do
    updates
    |> Enum.map(& &1.ip)
    |> Enum.filter(&(&1 not in [nil, ""]))
    |> Enum.uniq()
  end

  defp lookup_devices_by_ip(ips, alias_map) do
    remaining_ips = ips -- Map.keys(alias_map)

    case remaining_ips do
      [] ->
        %{}

      _ ->
        query =
          from(d in Device,
            where: d.ip in ^remaining_ips,
            select: {d.ip, d.uid}
          )

        Repo.all(query)
        |> Enum.filter(fn {_ip, uid} -> IdentityReconciler.serviceradar_uuid?(uid) end)
        |> Map.new()
    end
  end

  defp lookup_alias_device_ids_by_ip([]), do: %{}

  defp lookup_alias_device_ids_by_ip(ips) do
    query =
      from(a in DeviceAliasState,
        where:
          a.alias_type == :ip and a.alias_value in ^ips and
            a.state in [:confirmed, :updated],
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
      ids = effective_identifiers(update)

      cached_device_id(ids, existing_mappings) ||
        existing_device_id(update, ids, ip_to_device) ||
        IdentityReconciler.generate_deterministic_device_id(ids)
    end
  end

  defp cached_device_id(ids, existing_mappings) do
    lookup_cached(:agent_id, ids.agent_id, ids.partition, existing_mappings) ||
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
      classification = DeviceEnrichmentRules.classify(update)
      vendor_name = infer_vendor_name(update, classification)
      model = infer_model(update, classification)
      {device_type, device_type_id} = infer_device_type(update, classification)
      metadata = merge_classification_metadata(update.metadata || %{}, classification)
      owner = infer_owner(update, metadata)

      record = %{
        uid: device_id,
        ip: update.ip,
        mac: update.mac,
        hostname: update.hostname,
        name: update.hostname || update.ip,
        type: device_type,
        type_id: device_type_id,
        vendor_name: vendor_name,
        model: model,
        is_available: update.is_available || false,
        owner: owner,
        metadata: metadata,
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
    update_query = device_upsert_update_query()
    do_bulk_upsert_devices(records, update_query)
  rescue
    e ->
      Logger.warning("Bulk device upsert failed: #{inspect(e)}")
      {:error, e}
  end

  defp do_bulk_upsert_devices(records, update_query) do
    Repo.insert_all(
      Device,
      records,
      on_conflict: update_query,
      conflict_target: [:uid]
    )

    :ok
  rescue
    e in Postgrex.Error ->
      if ip_unique_conflict?(e) do
        recover_ip_conflict_and_retry(records, update_query, e)
      else
        Logger.warning("Bulk device upsert failed: #{inspect(e)}")
        {:error, e}
      end
  end

  defp recover_ip_conflict_and_retry(records, update_query, original_error) do
    recovered_records =
      records
      |> remap_records_to_existing_ip()
      |> merge_records_by_uid()

    if recovered_records == records do
      Logger.warning("Bulk device upsert failed: #{inspect(original_error)}")
      {:error, original_error}
    else
      Logger.warning(
        "Bulk device upsert hit active-IP conflict; remapped #{length(records)} records to #{length(recovered_records)} and retrying"
      )

      do_bulk_upsert_devices_once(recovered_records, update_query)
    end
  end

  defp do_bulk_upsert_devices_once(records, update_query) do
    Repo.insert_all(
      Device,
      records,
      on_conflict: update_query,
      conflict_target: [:uid]
    )

    :ok
  rescue
    e ->
      Logger.warning("Bulk device upsert retry failed: #{inspect(e)}")
      {:error, e}
  end

  defp remap_records_to_existing_ip(records) do
    ips =
      records
      |> Enum.map(&Map.get(&1, :ip))
      |> Enum.filter(&valid_ip?/1)
      |> Enum.uniq()

    existing_by_ip =
      if ips == [] do
        %{}
      else
        query =
          from(d in Device,
            where: d.ip in ^ips and is_nil(d.deleted_at),
            select: {d.ip, d.uid}
          )

        Repo.all(query) |> Map.new()
      end

    Enum.map(records, fn record ->
      ip = Map.get(record, :ip)

      case Map.get(existing_by_ip, ip) do
        nil -> record
        existing_uid -> Map.put(record, :uid, existing_uid)
      end
    end)
  end

  defp merge_records_by_uid(records) do
    records
    |> Enum.reduce(%{}, fn record, acc ->
      uid = Map.fetch!(record, :uid)
      Map.update(acc, uid, record, &merge_device_records(&1, record))
    end)
    |> Map.values()
  end

  defp merge_device_records(existing, incoming) do
    %{
      existing
      | ip: prefer_non_empty(incoming.ip, existing.ip),
        mac: prefer_non_empty(incoming.mac, existing.mac),
        hostname: prefer_non_empty(incoming.hostname, existing.hostname),
        name: prefer_non_empty(incoming.name, existing.name),
        type: prefer_non_empty(incoming.type, existing.type),
        type_id: prefer_positive_int(incoming.type_id, existing.type_id),
        vendor_name: prefer_non_empty(incoming.vendor_name, existing.vendor_name),
        model: prefer_non_empty(incoming.model, existing.model),
        is_available: incoming.is_available,
        owner: incoming.owner || existing.owner,
        metadata: Map.merge(existing.metadata || %{}, incoming.metadata || %{}),
        tags: Map.merge(existing.tags || %{}, incoming.tags || %{}),
        discovery_sources:
          (existing.discovery_sources || [])
          |> Kernel.++(incoming.discovery_sources || [])
          |> Enum.reject(&(&1 in [nil, ""]))
          |> Enum.uniq(),
        first_seen_time: existing.first_seen_time || incoming.first_seen_time,
        last_seen_time: incoming.last_seen_time || existing.last_seen_time,
        created_time: existing.created_time || incoming.created_time,
        modified_time: incoming.modified_time || existing.modified_time
    }
  end

  defp prefer_non_empty(new_value, old_value) when new_value in [nil, ""], do: old_value
  defp prefer_non_empty(new_value, _old_value), do: new_value

  defp prefer_positive_int(new_value, _old_value) when is_integer(new_value) and new_value > 0,
    do: new_value

  defp prefer_positive_int(_new_value, old_value), do: old_value

  defp valid_ip?(value) when is_binary(value), do: String.trim(value) != ""
  defp valid_ip?(_value), do: false

  defp ip_unique_conflict?(%Postgrex.Error{postgres: postgres}) when is_map(postgres) do
    postgres[:code] == :unique_violation and
      postgres[:constraint] == "ocsf_devices_unique_active_ip_idx"
  end

  defp ip_unique_conflict?(_), do: false

  defp device_upsert_update_query do
    from(d in Device,
      update: [
        set: [
          ip: fragment("COALESCE(EXCLUDED.ip, ?)", d.ip),
          mac: fragment("COALESCE(EXCLUDED.mac, ?)", d.mac),
          hostname: fragment("COALESCE(EXCLUDED.hostname, ?)", d.hostname),
          name: fragment("COALESCE(EXCLUDED.name, ?)", d.name),
          type:
            fragment(
              "COALESCE(NULLIF(EXCLUDED.type, ''), ?)",
              d.type
            ),
          type_id:
            fragment(
              "CASE WHEN EXCLUDED.type_id IS NOT NULL AND EXCLUDED.type_id > 0 THEN EXCLUDED.type_id ELSE ? END",
              d.type_id
            ),
          vendor_name: fragment("COALESCE(EXCLUDED.vendor_name, ?)", d.vendor_name),
          model: fragment("COALESCE(EXCLUDED.model, ?)", d.model),
          is_available: fragment("COALESCE(EXCLUDED.is_available, ?)", d.is_available),
          owner: fragment("COALESCE(EXCLUDED.owner, ?)", d.owner),
          metadata:
            fragment(
              "COALESCE(?, '{}'::jsonb) || COALESCE(EXCLUDED.metadata, '{}'::jsonb)",
              d.metadata
            ),
          deleted_at: nil,
          deleted_by: nil,
          deleted_reason: nil,
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
  end

  # Build identifier records for bulk upsert
  defp build_identifier_records(resolved_updates) do
    resolved_updates
    |> Enum.flat_map(fn {update, device_id} ->
      ids = effective_identifiers(update)
      partition = ids.partition
      include_agent? = include_agent_identifier?(update, ids)
      include_mac? = include_mac_identifier?(update)

      []
      |> maybe_add_identifier_record_if(
        include_agent?,
        device_id,
        :agent_id,
        ids.agent_id,
        partition
      )
      |> maybe_add_identifier_record(device_id, :armis_device_id, ids.armis_id, partition)
      |> maybe_add_identifier_record(device_id, :integration_id, ids.integration_id, partition)
      |> maybe_add_identifier_record(device_id, :netbox_device_id, ids.netbox_id, partition)
      |> maybe_add_identifier_record_if(include_mac?, device_id, :mac, ids.mac, partition)
    end)
    |> Enum.uniq_by(fn r -> {r.identifier_type, r.identifier_value, r.partition} end)
  end

  defp maybe_add_identifier_record(acc, _device_id, _type, nil, _partition), do: acc

  defp maybe_add_identifier_record(acc, device_id, type, value, partition) do
    [
      %{
        device_id: device_id,
        identifier_type: type,
        identifier_value: value,
        partition: partition,
        confidence: :strong,
        source: "sync_ingestor"
      }
      | acc
    ]
  end

  defp maybe_add_identifier_record_if(acc, false, _device_id, _type, _value, _partition), do: acc

  defp maybe_add_identifier_record_if(acc, true, device_id, type, value, partition) do
    maybe_add_identifier_record(acc, device_id, type, value, partition)
  end

  defp include_agent_identifier?(update, ids) do
    cond do
      ids.agent_id in [nil, ""] -> false
      mapper_like_source?(update) -> false
      true -> true
    end
  end

  defp include_mac_identifier?(update) do
    metadata = update.metadata || %{}

    cond do
      mapper_like_source?(update) -> mapper_primary_mac?(metadata)
      true -> true
    end
  end

  defp mapper_like_source?(update) do
    source = String.downcase(update.source || "")
    metadata = update.metadata || %{}
    identity_source = String.downcase(to_string(metadata["identity_source"] || ""))

    source in ["mapper", "sweep", "network_discovery"] or
      identity_source in ["mapper_ip_seed", "mapper_primary_mac_seed"]
  end

  defp mapper_primary_mac?(metadata) when is_map(metadata) do
    kind =
      metadata
      |> Map.get("identity_mac_kind", "")
      |> to_string()
      |> String.downcase()

    kind in ["primary", "management", "chassis"]
  end

  defp mapper_primary_mac?(_metadata), do: false

  defp effective_identifiers(update) do
    ids = IdentityReconciler.extract_strong_identifiers(update)

    if mapper_like_source?(update) do
      # Mapper agent_id identifies the scanner, not the discovered endpoint.
      %{ids | agent_id: nil}
    else
      ids
    end
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

  defp infer_vendor_name(update, classification) do
    metadata = update.metadata || %{}
    ruled_vendor = Map.get(classification, :vendor_name)

    explicit =
      get_string(metadata, [
        "vendor_name",
        "vendor",
        "manufacturer",
        "make",
        "vendorName"
      ])

    cond do
      explicit not in [nil, ""] ->
        explicit

      ruled_vendor not in [nil, ""] ->
        ruled_vendor

      (sys_descr = sys_descr_from_metadata(metadata)) not in [nil, ""] ->
        vendor_from_sys_descr(sys_descr)

      true ->
        nil
    end
  end

  defp infer_model(update, classification) do
    metadata = update.metadata || %{}
    explicit = get_string(metadata, ["model", "device_model", "model_name"])
    ruled_model = Map.get(classification, :model)

    cond do
      explicit not in [nil, ""] ->
        explicit

      ruled_model not in [nil, ""] ->
        ruled_model

      (sys_descr = sys_descr_from_metadata(metadata)) not in [nil, ""] ->
        parse_model_from_sys_descr(sys_descr)

      true ->
        nil
    end
  end

  defp infer_owner(update, metadata) do
    explicit_owner =
      update.metadata
      |> get_map(["owner", :owner])
      |> case do
        map when is_map(map) and map_size(map) > 0 -> map
        _ -> nil
      end

    cond do
      is_map(explicit_owner) ->
        explicit_owner

      (owner_name = get_string(metadata, ["sys_owner", "sys_contact", "sysContact"])) not in [
        nil,
        ""
      ] ->
        %{"name" => owner_name}

      true ->
        nil
    end
  end

  defp vendor_from_sys_descr(nil), do: nil

  defp vendor_from_sys_descr(sys_descr) when is_binary(sys_descr) do
    sys_descr = String.downcase(sys_descr)

    Enum.find_value(@vendor_tokens, fn {token, vendor} ->
      if String.contains?(sys_descr, token), do: vendor, else: nil
    end)
  end

  defp parse_model_from_sys_descr(sys_descr) when is_binary(sys_descr) do
    cleaned = String.trim(sys_descr)

    cond do
      cleaned == "" ->
        nil

      String.contains?(cleaned, ",") ->
        cleaned
        |> String.split(",", parts: 2)
        |> List.first()
        |> normalize_model_token()

      true ->
        cleaned
        |> String.split()
        |> List.first()
        |> normalize_model_token()
    end
  end

  defp normalize_model_token(nil), do: nil

  defp normalize_model_token(model) when is_binary(model) do
    token =
      model
      |> String.trim()
      |> String.trim_trailing(".")

    if token == "", do: nil, else: token
  end

  defp sys_descr_from_metadata(metadata) do
    get_string(metadata, ["sys_descr", "sysDescr", "sys_description", "sysDescr"])
  end

  defp infer_device_type(update, classification) do
    metadata = update.metadata || %{}
    explicit_type = infer_explicit_type(metadata)
    ruled_type = Map.get(classification, :type)
    ruled_type_id = Map.get(classification, :type_id)
    role = infer_role(metadata)

    cond do
      ruled_type not in [nil, ""] and is_integer(ruled_type_id) ->
        {ruled_type, ruled_type_id}

      explicit_type != nil ->
        explicit_type

      role in ["router"] ->
        {"Router", 12}

      role in ["switch_l2"] ->
        {"Switch", 10}

      role in ["ap_bridge"] ->
        {"Access Point", 99}

      true ->
        {nil, 0}
    end
  end

  defp infer_explicit_type(metadata) do
    explicit =
      get_string(metadata, [
        "type",
        "device_type",
        "deviceType",
        "type_name"
      ])

    cond do
      explicit in [nil, ""] ->
        nil

      true ->
        normalized = String.downcase(explicit)

        cond do
          normalized in ["router", "gateway"] ->
            {"Router", 12}

          normalized in ["switch", "switch_l2"] ->
            {"Switch", 10}

          normalized in ["access_point", "access point", "ap", "wireless_ap"] ->
            {"Access Point", 99}

          true ->
            {explicit, 99}
        end
    end
  end

  defp infer_role(metadata) do
    metadata
    |> get_string(["device_role", "_device_role"])
    |> to_string()
    |> String.downcase()
  end

  defp merge_classification_metadata(metadata, classification) do
    case Map.get(classification, :rule_id) do
      nil ->
        metadata

      rule_id ->
        metadata
        |> Map.put("classification_source", Map.get(classification, :source))
        |> Map.put("classification_rule_id", rule_id)
        |> Map.put("classification_confidence", Map.get(classification, :confidence))
        |> Map.put("classification_reason", Map.get(classification, :reason))
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

  defp process_alias_conflicts(resolved_updates, actor) do
    merged_ips =
      resolved_updates
      |> alias_conflict_candidates()
      |> Enum.reduce(MapSet.new(), fn {device_id, ids}, acc ->
        handle_alias_conflict(device_id, ids, actor, acc)
      end)

    if MapSet.size(merged_ips) > 0 do
      Logger.debug("SyncIngestor: merged alias conflicts for #{MapSet.size(merged_ips)} IPs")
    end

    :ok
  end

  defp alias_conflict_candidates(resolved_updates) do
    resolved_updates
    |> Enum.map(fn {update, device_id} ->
      ids = effective_identifiers(update)
      {update, device_id, ids}
    end)
    |> Enum.filter(fn {update, _device_id, ids} ->
      ids.ip != "" and alias_merge_allowed?(update, ids)
    end)
    |> Enum.map(fn {_update, device_id, ids} -> {device_id, ids} end)
  end

  defp alias_merge_allowed?(update, ids) do
    cond do
      has_non_mac_identifier?(update, ids) -> true
      mapper_like_source?(update) -> false
      true -> false
    end
  end

  defp has_non_mac_identifier?(update, ids) do
    source_has_agent_identity? = not mapper_like_source?(update)

    (source_has_agent_identity? and ids.agent_id not in [nil, ""]) or
      ids.armis_id not in [nil, ""] or
      ids.integration_id not in [nil, ""] or
      ids.netbox_id not in [nil, ""]
  end

  defp handle_alias_conflict(device_id, ids, actor, merged_ips) do
    if MapSet.member?(merged_ips, ids.ip) do
      merged_ips
    else
      do_handle_alias_conflict(device_id, ids, actor, merged_ips)
    end
  end

  defp do_handle_alias_conflict(device_id, ids, actor, merged_ips) do
    case IdentityReconciler.lookup_alias_device_id(ids.ip, ids.partition, actor) do
      {:ok, alias_device_id} when is_binary(alias_device_id) and alias_device_id != "" ->
        merge_alias_device(alias_device_id, device_id, ids, actor, merged_ips)

      _ ->
        merged_ips
    end
  end

  defp merge_alias_device(alias_device_id, device_id, ids, actor, merged_ips) do
    cond do
      alias_device_id == device_id ->
        MapSet.put(merged_ips, ids.ip)

      IdentityReconciler.service_device_id?(alias_device_id) ->
        MapSet.put(merged_ips, ids.ip)

      not IdentityReconciler.serviceradar_uuid?(device_id) ->
        MapSet.put(merged_ips, ids.ip)

      true ->
        attempt_alias_merge(alias_device_id, device_id, ids, actor, merged_ips)
    end
  end

  defp attempt_alias_merge(alias_device_id, device_id, ids, actor, merged_ips) do
    case IdentityReconciler.merge_devices(alias_device_id, device_id,
           actor: actor,
           reason: "ip_alias_conflict",
           details: %{
             source: "sync_ingestor",
             alias_ip: ids.ip,
             update_device_id: device_id
           }
         ) do
      :ok ->
        Logger.info(
          "SyncIngestor: merged alias device #{alias_device_id} into #{device_id} (ip=#{ids.ip})"
        )

        MapSet.put(merged_ips, ids.ip)

      {:error, reason} ->
        if alias_not_found?(reason) do
          Logger.info(
            "SyncIngestor: alias device #{alias_device_id} already merged for ip=#{ids.ip}"
          )

          MapSet.put(merged_ips, ids.ip)
        else
          Logger.warning(
            "SyncIngestor: failed to merge alias device #{alias_device_id} into #{device_id} (ip=#{ids.ip}): #{inspect(reason)}"
          )

          merged_ips
        end
    end
  end

  defp alias_not_found?(%Ash.Error.Invalid{errors: errors}) do
    Enum.any?(errors, &match?(%Ash.Error.Query.NotFound{}, &1))
  end

  defp alias_not_found?(_), do: false

  defp get_bool(map, keys) do
    case get_value(map, keys) do
      true -> true
      _ -> false
    end
  end
end
