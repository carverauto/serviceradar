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
  @vendor_tokens [
    {"ubiquiti", "Ubiquiti"},
    {"unifi", "Ubiquiti"},
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
    ip_to_device = bulk_lookup_by_ip(ip_only_updates(normalized_updates))

    resolved_updates =
      Enum.map(normalized_updates, fn update ->
        device_id = resolve_device_id_cached(update, existing_mappings, ip_to_device)
        {update, device_id}
      end)

    timestamp = DateTime.utc_now() |> DateTime.truncate(:second)
    device_records = build_device_upsert_records(resolved_updates, timestamp)
    identifier_records = build_identifier_records(resolved_updates)

    {resolved_updates, device_records, identifier_records}
  end

  defp ip_only_updates(normalized_updates) do
    Enum.filter(normalized_updates, fn update ->
      ids = IdentityReconciler.extract_strong_identifiers(update)
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
      vendor_name = infer_vendor_name(update)
      model = infer_model(update, vendor_name)

      record = %{
        uid: device_id,
        ip: update.ip,
        mac: update.mac,
        hostname: update.hostname,
        name: update.hostname || update.ip,
        vendor_name: vendor_name,
        model: model,
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
            vendor_name: fragment("COALESCE(EXCLUDED.vendor_name, ?)", d.vendor_name),
            model: fragment("COALESCE(EXCLUDED.model, ?)", d.model),
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

  defp infer_vendor_name(update) do
    metadata = update.metadata || %{}

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

      vendor_from_source(update.source, metadata) != nil ->
        vendor_from_source(update.source, metadata)

      (sys_descr = sys_descr_from_metadata(metadata)) not in [nil, ""] ->
        vendor_from_sys_descr(sys_descr)

      true ->
        nil
    end
  end

  defp infer_model(update, vendor_name) do
    metadata = update.metadata || %{}
    explicit = get_string(metadata, ["model", "device_model", "model_name"])

    cond do
      explicit not in [nil, ""] ->
        explicit

      vendor_name == "Ubiquiti" ->
        parse_ubiquiti_model(sys_descr_from_metadata(metadata))

      true ->
        nil
    end
  end

  defp vendor_from_source(source, metadata) do
    source = source || get_string(metadata, ["source", :source])
    src = String.downcase(to_string(source || ""))

    cond do
      src == "" -> nil
      String.contains?(src, "unifi") -> "Ubiquiti"
      String.contains?(src, "ubiquiti") -> "Ubiquiti"
      true -> nil
    end
  end

  defp vendor_from_sys_descr(nil), do: nil

  defp vendor_from_sys_descr(sys_descr) when is_binary(sys_descr) do
    sys_descr = String.downcase(sys_descr)

    Enum.find_value(@vendor_tokens, fn {token, vendor} ->
      if String.contains?(sys_descr, token), do: vendor, else: nil
    end)
  end

  defp parse_ubiquiti_model(nil), do: nil

  defp parse_ubiquiti_model(sys_descr) when is_binary(sys_descr) do
    parts = String.split(sys_descr)

    case Enum.find_index(parts, fn part ->
           String.downcase(part) == "unifi"
         end) do
      nil ->
        nil

      idx ->
        Enum.at(parts, idx + 1)
    end
  end

  defp sys_descr_from_metadata(metadata) do
    get_string(metadata, ["sys_descr", "sysDescr", "sys_description", "sysDescr"])
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
      {device_id, IdentityReconciler.extract_strong_identifiers(update)}
    end)
    |> Enum.filter(fn {_device_id, ids} ->
      IdentityReconciler.has_strong_identifier?(ids) and ids.ip != ""
    end)
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
