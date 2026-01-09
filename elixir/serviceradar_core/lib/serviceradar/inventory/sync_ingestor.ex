defmodule ServiceRadar.Inventory.SyncIngestor do
  @moduledoc """
  Ingests sync device updates and upserts OCSF device records using DIRE.

  Optimized for bulk operations to handle large batches efficiently.
  Uses batch DB queries and bulk upserts instead of one-by-one processing.
  """

  require Logger

  alias ServiceRadar.Cluster.TenantSchemas
  alias ServiceRadar.Inventory.{Device, DeviceIdentifier, IdentityReconciler}
  alias ServiceRadar.Repo

  import Ecto.Query

  # Process in chunks to balance memory vs DB efficiency
  @batch_size 500

  @spec ingest_updates([map()], String.t(), keyword()) :: :ok | {:error, term()}
  def ingest_updates(updates, tenant_id, opts \\ []) do
    actor = Keyword.get(opts, :actor, system_actor(tenant_id))
    tenant_schema = TenantSchemas.schema_for_tenant(tenant_id)

    updates = List.wrap(updates)
    total_count = length(updates)

    Logger.info("SyncIngestor: Processing #{total_count} updates in batches of #{@batch_size}")
    start_time = System.monotonic_time(:millisecond)

    # Process in batches
    updates
    |> Enum.chunk_every(@batch_size)
    |> Enum.with_index(1)
    |> Enum.each(fn {batch, batch_num} ->
      batch_start = System.monotonic_time(:millisecond)
      ingest_batch(batch, tenant_schema, actor)
      batch_elapsed = System.monotonic_time(:millisecond) - batch_start

      total_batches = ceil(total_count / @batch_size)
      Logger.debug(
        "SyncIngestor: Batch #{batch_num}/#{total_batches} (#{length(batch)} devices) completed in #{batch_elapsed}ms"
      )
    end)

    elapsed = System.monotonic_time(:millisecond) - start_time
    rate = if elapsed > 0, do: Float.round(total_count / (elapsed / 1000), 1), else: 0
    Logger.info("SyncIngestor: Completed #{total_count} updates in #{elapsed}ms (#{rate} devices/sec)")

    :ok
  end

  defp ingest_batch(updates, tenant_schema, actor) do
    # Step 1: Normalize all updates
    normalized_updates = Enum.map(updates, &normalize_update/1)

    # Step 2: Extract all identifiers for bulk lookup
    all_identifiers = extract_all_identifiers(normalized_updates)

    # Step 3: Bulk lookup existing device identifiers
    existing_mappings = bulk_lookup_identifiers(all_identifiers, tenant_schema)

    # Step 4: Bulk lookup existing devices by IP for IP-only devices
    ip_only_updates = Enum.filter(normalized_updates, fn u ->
      ids = IdentityReconciler.extract_strong_identifiers(u)
      not IdentityReconciler.has_strong_identifier?(ids) and ids.ip != ""
    end)
    ip_to_device = bulk_lookup_by_ip(ip_only_updates, tenant_schema)

    # Step 5: Resolve device IDs (using cached lookups)
    resolved_updates =
      Enum.map(normalized_updates, fn update ->
        device_id = resolve_device_id_cached(update, existing_mappings, ip_to_device)
        {update, device_id}
      end)

    # Step 6: Bulk lookup existing devices by UID
    device_ids = Enum.map(resolved_updates, fn {_, id} -> id end) |> Enum.uniq()
    existing_devices = bulk_lookup_devices_by_uid(device_ids, tenant_schema)

    # Step 7: Separate creates vs updates
    timestamp = DateTime.utc_now()
    {to_create, to_update} = partition_creates_and_updates(resolved_updates, existing_devices, timestamp)

    # Step 8: Bulk create new devices
    if length(to_create) > 0 do
      bulk_create_devices(to_create, tenant_schema)
    end

    # Step 9: Bulk update existing devices
    if length(to_update) > 0 do
      bulk_update_devices(to_update, tenant_schema)
    end

    # Step 10: Bulk upsert device identifiers
    identifier_records = build_identifier_records(resolved_updates)
    if length(identifier_records) > 0 do
      bulk_upsert_identifiers(identifier_records, tenant_schema)
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
  defp bulk_lookup_identifiers(identifiers, tenant_schema) when length(identifiers) == 0 do
    %{}
  end

  defp bulk_lookup_identifiers(identifiers, tenant_schema) do
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

    Repo.all(query, prefix: tenant_schema)
    |> Enum.reduce(%{}, fn {type, value, partition, device_id}, acc ->
      key = {String.to_atom(type), value, partition}
      Map.put(acc, key, device_id)
    end)
  rescue
    e ->
      Logger.warning("Bulk identifier lookup failed: #{inspect(e)}")
      %{}
  end

  # Bulk lookup devices by IP
  defp bulk_lookup_by_ip(updates, _tenant_schema) when length(updates) == 0 do
    %{}
  end

  defp bulk_lookup_by_ip(updates, tenant_schema) do
    ips = updates
          |> Enum.map(fn u -> u.ip end)
          |> Enum.filter(&(&1 != nil and &1 != ""))
          |> Enum.uniq()

    if length(ips) == 0 do
      %{}
    else
      query =
        from(d in Device,
          where: d.ip in ^ips,
          select: {d.ip, d.uid}
        )

      Repo.all(query, prefix: tenant_schema)
      |> Enum.filter(fn {_ip, uid} -> IdentityReconciler.serviceradar_uuid?(uid) end)
      |> Map.new()
    end
  rescue
    e ->
      Logger.warning("Bulk IP lookup failed: #{inspect(e)}")
      %{}
  end

  # Resolve device ID using cached lookups
  defp resolve_device_id_cached(update, existing_mappings, ip_to_device) do
    # Skip service component IDs
    if IdentityReconciler.service_device_id?(update.device_id) do
      update.device_id
    else
      ids = IdentityReconciler.extract_strong_identifiers(update)

      # Try cached lookups in priority order
      cached_device_id =
        lookup_cached(:armis_device_id, ids.armis_id, ids.partition, existing_mappings) ||
        lookup_cached(:integration_id, ids.integration_id, ids.partition, existing_mappings) ||
        lookup_cached(:netbox_device_id, ids.netbox_id, ids.partition, existing_mappings) ||
        lookup_cached(:mac, ids.mac, ids.partition, existing_mappings)

      cond do
        cached_device_id != nil ->
          cached_device_id

        IdentityReconciler.serviceradar_uuid?(update.device_id) ->
          update.device_id

        ids.ip != "" and Map.has_key?(ip_to_device, ids.ip) ->
          Map.get(ip_to_device, ids.ip)

        true ->
          IdentityReconciler.generate_deterministic_device_id(ids)
      end
    end
  end

  defp lookup_cached(_type, nil, _partition, _mappings), do: nil
  defp lookup_cached(type, value, partition, mappings) do
    Map.get(mappings, {type, value, partition})
  end

  # Bulk lookup devices by UID
  defp bulk_lookup_devices_by_uid(device_ids, _tenant_schema) when length(device_ids) == 0 do
    MapSet.new()
  end

  defp bulk_lookup_devices_by_uid(device_ids, tenant_schema) do
    query =
      from(d in Device,
        where: d.uid in ^device_ids,
        select: d.uid
      )

    Repo.all(query, prefix: tenant_schema)
    |> MapSet.new()
  rescue
    e ->
      Logger.warning("Bulk device lookup failed: #{inspect(e)}")
      MapSet.new()
  end

  # Partition updates into creates and updates
  defp partition_creates_and_updates(resolved_updates, existing_devices, timestamp) do
    Enum.reduce(resolved_updates, {[], []}, fn {update, device_id}, {creates, updates} ->
      {create_attrs, update_attrs} = build_device_attrs(update, device_id, timestamp)

      if MapSet.member?(existing_devices, device_id) do
        update_attrs = Map.put(update_attrs, :uid, device_id)
        update_attrs = Map.put(update_attrs, :last_seen_time, timestamp)
        {creates, [update_attrs | updates]}
      else
        {[create_attrs | creates], updates}
      end
    end)
  end

  # Bulk create devices using insert_all
  defp bulk_create_devices(records, tenant_schema) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    # Prepare records for insert_all (need to add timestamps and convert to maps)
    insert_records =
      records
      |> Enum.map(fn attrs ->
        %{
          id: Ecto.UUID.generate(),
          uid: attrs[:uid],
          ip: attrs[:ip],
          mac: attrs[:mac],
          hostname: attrs[:hostname],
          name: attrs[:name] || attrs[:hostname] || attrs[:ip],
          is_available: attrs[:is_available] || false,
          metadata: attrs[:metadata] || %{},
          first_seen_time: attrs[:first_seen_time] || now,
          last_seen_time: now,
          created_time: attrs[:created_time] || now,
          modified_time: now
        }
      end)
      |> Enum.uniq_by(& &1.uid)  # Dedupe by uid within batch

    if length(insert_records) > 0 do
      Repo.insert_all(
        Device,
        insert_records,
        prefix: tenant_schema,
        on_conflict: :nothing,  # Skip conflicts (device already exists)
        conflict_target: [:uid]
      )
    end
  rescue
    e ->
      Logger.warning("Bulk device create failed: #{inspect(e)}, falling back to individual creates")
      # Fallback to individual creates for better error handling
      Enum.each(records, fn attrs ->
        try do
          Device
          |> Ash.Changeset.for_create(:create, attrs)
          |> Ash.create(tenant: tenant_schema, authorize?: false)
        rescue
          _ -> :ok
        end
      end)
  end

  # Bulk update devices - using update_all with CASE statement
  defp bulk_update_devices(records, tenant_schema) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    # Group updates by uid
    records_by_uid = Map.new(records, fn r -> {r.uid, r} end)
    uids = Map.keys(records_by_uid)

    if length(uids) > 0 do
      # For bulk updates, we do multiple smaller updates grouped by field values
      # to avoid overly complex queries. Update in smaller batches.
      Enum.chunk_every(uids, 100)
      |> Enum.each(fn uid_batch ->
        batch_records = Enum.map(uid_batch, &Map.get(records_by_uid, &1))

        # Update each device individually but with minimal overhead
        # This is still faster than Ash changesets due to reduced overhead
        Enum.each(batch_records, fn attrs ->
          uid = attrs.uid

          update_fields = %{
            ip: attrs[:ip],
            mac: attrs[:mac],
            hostname: attrs[:hostname],
            name: attrs[:name] || attrs[:hostname] || attrs[:ip],
            is_available: attrs[:is_available] || false,
            metadata: attrs[:metadata] || %{},
            last_seen_time: attrs[:last_seen_time] || now,
            modified_time: now
          }
          |> Enum.reject(fn {_k, v} -> is_nil(v) end)
          |> Map.new()

          from(d in Device, where: d.uid == ^uid)
          |> Repo.update_all([set: Map.to_list(update_fields)], prefix: tenant_schema)
        end)
      end)
    end
  rescue
    e ->
      Logger.warning("Bulk device update failed: #{inspect(e)}")
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
  defp bulk_upsert_identifiers(records, tenant_schema) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    insert_records =
      Enum.map(records, fn r ->
        Map.merge(r, %{
          first_seen: now,
          last_seen: now
        })
      end)

    if length(insert_records) > 0 do
      Repo.insert_all(
        DeviceIdentifier,
        insert_records,
        prefix: tenant_schema,
        on_conflict: {:replace, [:device_id, :last_seen]},
        conflict_target: [:identifier_type, :identifier_value, :partition]
      )
    end
  rescue
    e ->
      Logger.warning("Bulk identifier upsert failed: #{inspect(e)}")
  end

  defp normalize_update(update) when is_map(update) do
    %{
      device_id: get_string(update, ["device_id", :device_id]),
      ip: get_string(update, ["ip", :ip]),
      mac: get_string(update, ["mac", :mac]),
      hostname: get_string(update, ["hostname", :hostname]),
      partition: get_string(update, ["partition", :partition]) || "default",
      metadata: get_map(update, ["metadata", :metadata]),
      timestamp: parse_timestamp(get_value(update, ["timestamp", :timestamp])),
      is_available: get_bool(update, ["is_available", :is_available])
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
      timestamp: nil,
      is_available: false
    }
  end

  defp build_device_attrs(update, device_id, timestamp) do
    metadata = update.metadata || %{}

    update_attrs = %{
      ip: update.ip,
      mac: update.mac,
      hostname: update.hostname,
      name: update.hostname || update.ip,
      is_available: update.is_available,
      metadata: metadata
    }

    create_attrs =
      update_attrs
      |> Map.put(:uid, device_id)
      |> Map.put(:first_seen_time, timestamp)
      |> Map.put(:created_time, timestamp)

    {create_attrs, update_attrs}
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

  defp get_bool(map, keys) do
    case get_value(map, keys) do
      true -> true
      _ -> false
    end
  end

  defp system_actor(tenant_id) do
    %{
      id: "system",
      email: "gateway@serviceradar",
      role: :admin,
      tenant_id: tenant_id
    }
  end
end
