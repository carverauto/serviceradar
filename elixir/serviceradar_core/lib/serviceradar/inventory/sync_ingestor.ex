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
        ingest_batch(batch, tenant_schema, actor)
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

  defp ingest_batch(updates, tenant_schema, _actor) do
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

    # Step 6: Build device upsert records
    timestamp = DateTime.utc_now() |> DateTime.truncate(:second)
    device_records = build_device_upsert_records(resolved_updates, timestamp)

    # Step 7: Bulk upsert devices
    device_result =
      if length(device_records) > 0 do
        bulk_upsert_devices(device_records, tenant_schema)
      else
        :ok
      end

    # Step 8: Bulk upsert device identifiers
    identifier_records = build_identifier_records(resolved_updates)
    identifier_result =
      if length(identifier_records) > 0 do
        bulk_upsert_identifiers(identifier_records, tenant_schema)
      else
        :ok
      end

    case {device_result, identifier_result} do
      {:ok, :ok} -> :ok
      {{:error, _} = error, _} -> error
      {_, {:error, _} = error} -> error
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
  defp bulk_lookup_identifiers(identifiers, _tenant_schema) when length(identifiers) == 0 do
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

  defp build_device_upsert_records(resolved_updates, timestamp) do
    resolved_updates
    |> Enum.reduce(%{}, fn {update, device_id}, acc ->
      record = %{
        uid: device_id,
        ip: update.ip,
        mac: update.mac,
        hostname: update.hostname,
        name: update.hostname || update.ip,
        is_available: update.is_available || false,
        metadata: update.metadata || %{},
        first_seen_time: timestamp,
        last_seen_time: timestamp,
        created_time: timestamp,
        modified_time: timestamp
      }

      Map.put(acc, device_id, record)
    end)
    |> Map.values()
  end

  defp bulk_upsert_devices(records, tenant_schema) do
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
            last_seen_time: fragment("EXCLUDED.last_seen_time"),
            modified_time: fragment("EXCLUDED.modified_time")
          ]
        ]
      )

    Repo.insert_all(
      Device,
      records,
      prefix: tenant_schema,
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
