defmodule ServiceRadar.WifiMap.BatchIngestor do
  @moduledoc """
  Persists WiFi map plugin batches into platform-owned WiFi map tables.

  The external plugin is expected to send a normalized JSON payload through the
  existing plugin result pipeline. This ingestor deliberately performs no DDL
  and no customer-repository access; it only upserts rows into the schema owned
  by ServiceRadar migrations.
  """

  alias ServiceRadar.EventWriter.FieldParser
  alias ServiceRadar.Inventory.IdentityReconciler
  alias ServiceRadar.Inventory.SyncIngestor
  alias ServiceRadar.Repo

  require Logger

  @prefix "platform"
  @schema_names MapSet.new(["serviceradar.wifi_map.batch.v1", "wifi_map_batch.v1"])
  @payload_kinds MapSet.new(["wifi_map", "wifi_map_batch", "wifi-map-batch"])
  @max_insert_params 30_000

  @type context :: %{
          actor: term(),
          batch_id: String.t(),
          collection_timestamp: DateTime.t(),
          now: DateTime.t(),
          partition: String.t(),
          source_id: String.t(),
          source_kind: String.t(),
          source_name: String.t(),
          source_upsert: function(),
          batch_upsert: function(),
          bulk_upsert: function()
        }

  @spec ingest(map() | list(), map(), keyword()) :: :ok | {:error, term()}
  def ingest(payload, status, opts \\ [])

  def ingest(payload, status, opts) when is_list(payload) do
    payload
    |> Enum.find(&is_map/1)
    |> case do
      nil -> :ok
      entry -> ingest(entry, status, opts)
    end
  end

  def ingest(payload, status, opts) when is_map(payload) do
    case wifi_map_body(payload) do
      nil ->
        :ok

      body ->
        do_ingest(body, payload, status, opts)
    end
  rescue
    e ->
      Logger.error("WiFi map batch ingest failed: #{Exception.message(e)}")
      {:error, e}
  end

  def ingest(_payload, _status, _opts), do: :ok

  defp do_ingest(body, payload, status, opts) do
    now = DateTime.truncate(DateTime.utc_now(), :microsecond)
    collection_timestamp = collection_timestamp(body, payload, status)
    actor = Keyword.get(opts, :actor)
    source_upsert = Keyword.get(opts, :source_upsert, &upsert_source/2)
    batch_upsert = Keyword.get(opts, :batch_upsert, &upsert_batch/2)
    bulk_upsert = Keyword.get(opts, :bulk_upsert, &bulk_upsert/5)
    device_sync = Keyword.get(opts, :device_sync, &sync_device_inventory/2)
    use_transaction? = default_persistence?(opts)

    source_attrs = source_attrs(body, payload, status, collection_timestamp, now)
    device_updates = device_inventory_updates(body, status, source_attrs, collection_timestamp)

    run_ingest = fn ->
      persist_batch(
        body,
        actor,
        status,
        source_attrs,
        collection_timestamp,
        now,
        source_upsert,
        batch_upsert,
        bulk_upsert
      )
    end

    if_result =
      if use_transaction? do
        case Repo.transaction(fn ->
               case run_ingest.() do
                 :ok -> :ok
                 {:error, reason} -> Repo.rollback(reason)
               end
             end) do
          {:ok, :ok} -> :ok
          {:error, reason} -> {:error, reason}
        end
      else
        run_ingest.()
      end

    case if_result do
      :ok -> sync_devices(device_updates, actor, device_sync)
      other -> other
    end
  end

  defp persist_batch(
         body,
         actor,
         status,
         source_attrs,
         collection_timestamp,
         now,
         source_upsert,
         batch_upsert,
         bulk_upsert
       ) do
    with {:ok, source_id} <- source_upsert.(source_attrs, %{actor: actor}),
         batch_attrs = batch_attrs(body, source_id, collection_timestamp, now),
         {:ok, batch_id} <- batch_upsert.(batch_attrs, %{actor: actor}),
         context = %{
           actor: actor,
           batch_id: batch_id,
           collection_timestamp: collection_timestamp,
           now: now,
           partition: partition_value(status),
           source_id: source_id,
           source_kind: source_attrs.source_kind,
           source_name: source_attrs.name,
           source_upsert: source_upsert,
           batch_upsert: batch_upsert,
           bulk_upsert: bulk_upsert
         },
         :ok <- persist_site_references(body, context),
         :ok <- persist_sites(body, context),
         :ok <- persist_site_snapshots(body, context),
         :ok <- persist_access_points(body, context),
         :ok <- persist_controllers(body, context),
         :ok <- persist_radius_groups(body, context) do
      persist_fleet_history(body, context)
    end
  end

  defp default_persistence?(opts) do
    not Keyword.has_key?(opts, :source_upsert) and not Keyword.has_key?(opts, :batch_upsert) and
      not Keyword.has_key?(opts, :bulk_upsert)
  end

  defp wifi_map_body(payload) do
    payload
    |> candidate_payloads()
    |> Enum.find_value(fn candidate ->
      cond do
        not is_map(candidate) ->
          nil

        wifi_map_payload?(candidate) ->
          nested =
            map_value(candidate, ["wifi_map", "wifiMap", "data", "batch"]) ||
              candidate

          if is_map(nested), do: nested

        true ->
          nested = map_value(candidate, ["wifi_map", "wifiMap"])
          if is_map(nested) and wifi_map_payload?(nested), do: nested
      end
    end)
  end

  defp candidate_payloads(payload) do
    details =
      payload
      |> fetch_value(["details"])
      |> decode_json_map()

    Enum.reject([payload, details], &is_nil/1)
  end

  defp wifi_map_payload?(payload) when is_map(payload) do
    schema =
      payload
      |> string_value(["schema", "schema_name", "schemaName"])
      |> downcase()

    kind =
      payload
      |> string_value(["kind", "type", "payload_type", "payloadType"])
      |> downcase()

    MapSet.member?(@schema_names, schema) or MapSet.member?(@payload_kinds, kind)
  end

  defp persist_site_references(body, context) do
    body
    |> list_value(["site_references", "siteReferences", "airports", "references"])
    |> Enum.map(&site_reference_attrs(&1, body, context))
    |> Enum.reject(&is_nil/1)
    |> context.bulk_upsert.(
      :wifi_site_references,
      [:source_id, :site_code],
      [
        :name,
        :site_type,
        :region,
        :latitude,
        :longitude,
        :reference_hash,
        :reference_metadata,
        :updated_at
      ],
      context
    )
  end

  defp persist_sites(body, context) do
    body
    |> list_value(["sites"])
    |> Enum.map(&site_attrs(&1, context))
    |> Enum.reject(&is_nil/1)
    |> context.bulk_upsert.(
      :wifi_sites,
      [:source_id, :site_code],
      [
        :name,
        :site_type,
        :region,
        :latitude,
        :longitude,
        :metadata,
        :last_seen_at,
        :updated_at
      ],
      context
    )
  end

  defp persist_site_snapshots(body, context) do
    rows =
      body
      |> list_value(["site_snapshots", "siteSnapshots"])
      |> case do
        [] -> list_value(body, ["sites"])
        snapshots -> snapshots
      end
      |> Enum.map(&site_snapshot_attrs(&1, context))
      |> Enum.reject(&is_nil/1)

    context.bulk_upsert.(
      rows,
      :wifi_site_snapshots,
      [:source_id, :site_code, :collection_timestamp],
      [
        :batch_id,
        :ap_count,
        :up_count,
        :down_count,
        :model_breakdown,
        :controller_names,
        :wlc_count,
        :wlc_model_breakdown,
        :aos_version_breakdown,
        :server_group,
        :cluster,
        :all_server_groups,
        :aaa_profile,
        :metadata,
        :updated_at
      ],
      context
    )
  end

  defp persist_access_points(body, context) do
    rows =
      body
      |> device_rows([
        "access_points",
        "accessPoints",
        "aps",
        "ap_observations",
        "apObservations"
      ])
      |> Enum.map(&access_point_attrs(&1, context))
      |> Enum.reject(&is_nil/1)

    context.bulk_upsert.(
      rows,
      :wifi_access_point_observations,
      [:source_id, :collection_timestamp, :name],
      [
        :batch_id,
        :device_uid,
        :site_code,
        :hostname,
        :mac,
        :serial,
        :ip,
        :status,
        :model,
        :vendor_name,
        :metadata,
        :updated_at
      ],
      context
    )
  end

  defp persist_controllers(body, context) do
    rows =
      body
      |> controller_rows()
      |> Enum.map(&controller_attrs(&1, context))
      |> Enum.reject(&is_nil/1)

    context.bulk_upsert.(
      rows,
      :wifi_controller_observations,
      [:source_id, :collection_timestamp, :name],
      [
        :batch_id,
        :device_uid,
        :site_code,
        :hostname,
        :ip,
        :mac,
        :base_mac,
        :serial,
        :model,
        :aos_version,
        :psu_status,
        :uptime,
        :reboot_cause,
        :metadata,
        :updated_at
      ],
      context
    )
  end

  defp persist_radius_groups(body, context) do
    rows =
      body
      |> radius_group_rows()
      |> Enum.map(&radius_group_attrs(&1, context))
      |> Enum.reject(&is_nil/1)

    context.bulk_upsert.(
      rows,
      :wifi_radius_group_observations,
      [:source_id, :site_code, :controller_alias, :aaa_profile, :collection_timestamp],
      [
        :batch_id,
        :controller_device_uid,
        :server_group,
        :cluster,
        :all_server_groups,
        :status,
        :metadata,
        :updated_at
      ],
      context
    )
  end

  defp radius_group_rows(body) do
    explicit_rows =
      list_value(body, ["radius_groups", "radiusGroups", "radius_group_observations"])

    case explicit_rows do
      [] -> site_radius_group_rows(body)
      rows -> rows
    end
  end

  defp site_radius_group_rows(body) do
    body
    |> list_value(["site_snapshots", "siteSnapshots"])
    |> case do
      [] -> list_value(body, ["sites"])
      snapshots -> snapshots
    end
    |> Enum.map(&site_radius_group_row/1)
    |> Enum.reject(&is_nil/1)
  end

  defp site_radius_group_row(row) when is_map(row) do
    site_code = site_code(row)
    server_group = string_value(row, ["server_group", "serverGroup"])
    all_server_groups = string_list(row, ["all_server_groups", "allServerGroups"])
    cluster = string_value(row, ["cluster"])

    if blank?(site_code) or (blank?(server_group) and all_server_groups == [] and blank?(cluster)) do
      nil
    else
      %{
        "site_code" => site_code,
        "controller_alias" => "site:#{site_code}",
        "aaa_profile" => string_value(row, ["aaa_profile", "aaaProfile"]) || "site_summary",
        "server_group" => server_group,
        "cluster" => cluster,
        "all_server_groups" => all_server_groups,
        "status" => "OK",
        "metadata" => %{"scope" => "site_summary"}
      }
    end
  end

  defp site_radius_group_row(_row), do: nil

  defp persist_fleet_history(body, context) do
    body
    |> list_value(["fleet_history", "fleetHistory", "history"])
    |> Enum.map(&fleet_history_attrs(&1, context))
    |> Enum.reject(&is_nil/1)
    |> context.bulk_upsert.(
      :wifi_fleet_history,
      [:source_id, :build_date],
      [
        :batch_id,
        :ap_total,
        :count_2xx,
        :count_3xx,
        :count_4xx,
        :count_5xx,
        :count_6xx,
        :count_7xx,
        :count_other,
        :count_ap325,
        :pct_6xx,
        :pct_legacy,
        :site_count,
        :metadata,
        :updated_at
      ],
      context
    )
  end

  defp source_attrs(body, payload, status, collection_timestamp, now) do
    source = map_value(body, ["source"]) || map_value(payload, ["source"]) || %{}
    reference_hash = string_value(body, ["reference_hash", "referenceHash"])

    %{
      source_id:
        source
        |> string_value(["source_id", "sourceId", "id"])
        |> uuid_binary_or_generate(),
      plugin_source_id:
        source
        |> uuid_value(["plugin_source_id", "pluginSourceId"])
        |> uuid_binary(),
      name:
        string_value(source, ["name"]) ||
          string_value(body, ["source_name", "sourceName"]) ||
          status[:service_name] ||
          "wifi-map-seed",
      source_kind:
        string_value(source, ["source_kind", "sourceKind", "kind"]) ||
          string_value(body, ["source_kind", "sourceKind"]) ||
          "wifi_map_seed",
      latest_collection_at: collection_timestamp,
      latest_reference_hash: reference_hash,
      latest_reference_at: if(reference_hash, do: collection_timestamp),
      metadata: map_value(source, ["metadata"]) || %{},
      inserted_at: now,
      updated_at: now
    }
  end

  defp batch_attrs(body, source_id, collection_timestamp, now) do
    %{
      batch_id:
        body
        |> string_value(["batch_id", "batchId"])
        |> uuid_binary_or_generate(),
      source_id: source_id,
      collection_mode:
        string_value(body, ["collection_mode", "collectionMode", "mode"]) || "seed_snapshot",
      collection_timestamp: collection_timestamp,
      reference_hash: string_value(body, ["reference_hash", "referenceHash"]),
      source_files: map_value(body, ["source_files", "sourceFiles"]) || %{},
      row_counts: map_value(body, ["row_counts", "rowCounts"]) || inferred_row_counts(body),
      diagnostics: map_value(body, ["diagnostics"]) || %{},
      inserted_at: now
    }
  end

  defp site_reference_attrs(row, body, context) when is_map(row) do
    site_code = site_code(row)

    if blank?(site_code) do
      nil
    else
      %{
        source_id: context.source_id,
        site_code: site_code,
        name: string_value(row, ["name", "airport_name", "airportName"]) || site_code,
        site_type: site_type(row),
        region: string_value(row, ["region"]),
        latitude: float_value(row, ["lat", "latitude", "latitude_deg", "latitudeDeg"]),
        longitude: float_value(row, ["lon", "lng", "longitude", "longitude_deg", "longitudeDeg"]),
        reference_hash:
          string_value(row, ["reference_hash", "referenceHash"]) ||
            string_value(body, ["reference_hash", "referenceHash"]),
        reference_metadata: metadata(row, site_reference_known_keys()),
        updated_at: context.now
      }
    end
  end

  defp site_reference_attrs(_row, _body, _context), do: nil

  defp site_attrs(row, context) when is_map(row) do
    site_code = site_code(row)

    if blank?(site_code) do
      nil
    else
      %{
        source_id: context.source_id,
        site_code: site_code,
        name: string_value(row, ["name", "airport_name", "airportName"]) || site_code,
        site_type: site_type(row),
        region: string_value(row, ["region"]),
        latitude: float_value(row, ["lat", "latitude"]),
        longitude: float_value(row, ["lon", "lng", "longitude"]),
        metadata: metadata(row, site_known_keys()),
        first_seen_at:
          datetime_value(row, ["first_seen_at", "firstSeenAt"]) || context.collection_timestamp,
        last_seen_at:
          datetime_value(row, ["last_seen_at", "lastSeenAt"]) || context.collection_timestamp,
        inserted_at: context.now,
        updated_at: context.now
      }
    end
  end

  defp site_attrs(_row, _context), do: nil

  defp site_snapshot_attrs(row, context) when is_map(row) do
    site_code = site_code(row)

    if blank?(site_code) do
      nil
    else
      %{
        id: row |> string_value(["id"]) |> uuid_binary_or_generate(),
        source_id: context.source_id,
        batch_id: context.batch_id,
        site_code: site_code,
        collection_timestamp:
          datetime_value(row, ["collection_timestamp", "collectionTimestamp"]) ||
            context.collection_timestamp,
        ap_count: integer_value(row, ["ap_count", "apCount"]) || 0,
        up_count: integer_value(row, ["up_count", "upCount"]) || 0,
        down_count: integer_value(row, ["down_count", "downCount"]) || 0,
        model_breakdown: counter_map(row, ["models", "model_breakdown", "modelBreakdown"]),
        controller_names:
          string_list(row, ["controllers", "controller_names", "controllerNames"]),
        wlc_count: integer_value(row, ["wlc_count", "wlcCount"]) || 0,
        wlc_model_breakdown:
          counter_map(row, ["wlcs", "wlc_model_breakdown", "wlcModelBreakdown"]),
        aos_version_breakdown:
          counter_map(row, ["aos_versions", "aos_version_breakdown", "aosVersionBreakdown"]),
        server_group: string_value(row, ["server_group", "serverGroup"]),
        cluster: string_value(row, ["cluster"]),
        all_server_groups: string_list(row, ["all_server_groups", "allServerGroups"]),
        aaa_profile: string_value(row, ["aaa_profile", "aaaProfile"]),
        metadata: metadata(row, site_snapshot_known_keys()),
        inserted_at: context.now,
        updated_at: context.now
      }
    end
  end

  defp site_snapshot_attrs(_row, _context), do: nil

  defp access_point_attrs(row, context) when is_map(row) do
    site_code = site_code(row)
    name = string_value(row, ["name", "ap_name", "apName", "hostname", "host"])

    if blank?(site_code) or blank?(name) do
      nil
    else
      %{
        id: row |> string_value(["id"]) |> uuid_binary_or_generate(),
        source_id: context.source_id,
        batch_id: context.batch_id,
        device_uid: wifi_device_uid(row, :access_point, context),
        site_code: site_code,
        collection_timestamp:
          datetime_value(row, ["collection_timestamp", "collectionTimestamp"]) ||
            context.collection_timestamp,
        name: name,
        hostname: string_value(row, ["hostname", "host", "ap_name", "apName"]),
        mac: normalize_mac(string_value(row, ["mac", "wired_mac", "wiredMac"])),
        serial: string_value(row, ["serial", "serial_number", "serialNumber"]),
        ip: string_value(row, ["ip", "ip_address", "ipAddress"]),
        status: string_value(row, ["status"]),
        model: string_value(row, ["model"]),
        vendor_name: string_value(row, ["vendor_name", "vendorName", "vendor"]),
        metadata: metadata(row, access_point_known_keys()),
        inserted_at: context.now,
        updated_at: context.now
      }
    end
  end

  defp access_point_attrs(_row, _context), do: nil

  defp controller_attrs(row, context) when is_map(row) do
    site_code = site_code(row)

    name =
      string_value(row, [
        "name",
        "alias",
        "controller_alias",
        "controllerAlias",
        "device_alias",
        "deviceAlias",
        "hostname",
        "expected_name",
        "expectedName"
      ])

    if blank?(site_code) or blank?(name) do
      nil
    else
      %{
        id: row |> string_value(["id"]) |> uuid_binary_or_generate(),
        source_id: context.source_id,
        batch_id: context.batch_id,
        device_uid: wifi_device_uid(row, :controller, context),
        site_code: site_code,
        collection_timestamp:
          datetime_value(row, ["collection_timestamp", "collectionTimestamp"]) ||
            context.collection_timestamp,
        name: name,
        hostname: string_value(row, ["hostname", "host", "expected_name", "expectedName"]),
        ip: string_value(row, ["ip", "ip_address", "ipAddress", "switch_ip", "switchIp"]),
        mac: normalize_mac(string_value(row, ["mac", "mac_address", "macAddress"])),
        base_mac:
          normalize_mac(string_value(row, ["base_mac", "baseMac", "hw_base_mac", "hwBaseMac"])),
        serial:
          string_value(row, [
            "serial",
            "serial_number",
            "serialNumber",
            "chassis_serial",
            "chassisSerial"
          ]),
        model: string_value(row, ["model"]),
        aos_version: string_value(row, ["aos_version", "aosVersion", "version"]),
        psu_status: string_value(row, ["psu_status", "psuStatus"]),
        uptime: string_value(row, ["uptime"]),
        reboot_cause: string_value(row, ["reboot_cause", "rebootCause"]),
        metadata: metadata(row, controller_known_keys()),
        inserted_at: context.now,
        updated_at: context.now
      }
    end
  end

  defp controller_attrs(_row, _context), do: nil

  defp radius_group_attrs(row, context) when is_map(row) do
    site_code = site_code(row)

    controller_alias =
      string_value(row, [
        "controller_alias",
        "controllerAlias",
        "device_alias",
        "deviceAlias",
        "alias",
        "name"
      ])

    aaa_profile = string_value(row, ["aaa_profile", "aaaProfile", "profile"])

    if blank?(site_code) or blank?(controller_alias) or blank?(aaa_profile) do
      nil
    else
      %{
        id: row |> string_value(["id"]) |> uuid_binary_or_generate(),
        source_id: context.source_id,
        batch_id: context.batch_id,
        controller_device_uid:
          string_value(row, [
            "controller_device_uid",
            "controllerDeviceUid",
            "device_uid",
            "deviceUid"
          ]),
        site_code: site_code,
        collection_timestamp:
          datetime_value(row, ["collection_timestamp", "collectionTimestamp"]) ||
            context.collection_timestamp,
        controller_alias: controller_alias,
        aaa_profile: aaa_profile,
        server_group: string_value(row, ["server_group", "serverGroup", "dot1x_server_group"]),
        cluster: string_value(row, ["cluster", "server_group_location", "serverGroupLocation"]),
        all_server_groups: string_list(row, ["all_server_groups", "allServerGroups"]),
        status: string_value(row, ["status"]),
        metadata: metadata(row, radius_group_known_keys()),
        inserted_at: context.now,
        updated_at: context.now
      }
    end
  end

  defp radius_group_attrs(_row, _context), do: nil

  defp fleet_history_attrs(row, context) when is_map(row) do
    case date_value(row, ["build_date", "buildDate", "date"]) do
      nil ->
        nil

      build_date ->
        %{
          source_id: context.source_id,
          batch_id: context.batch_id,
          build_date: build_date,
          ap_total: integer_value(row, ["ap_total", "apTotal"]) || 0,
          count_2xx: integer_value(row, ["count_2xx", "count2xx"]) || 0,
          count_3xx: integer_value(row, ["count_3xx", "count3xx"]) || 0,
          count_4xx: integer_value(row, ["count_4xx", "count4xx"]) || 0,
          count_5xx: integer_value(row, ["count_5xx", "count5xx"]) || 0,
          count_6xx: integer_value(row, ["count_6xx", "count6xx"]) || 0,
          count_7xx: integer_value(row, ["count_7xx", "count7xx"]) || 0,
          count_other: integer_value(row, ["count_other", "countOther"]) || 0,
          count_ap325: integer_value(row, ["count_ap325", "countAp325"]),
          pct_6xx: float_value(row, ["pct_6xx", "pct6xx"]),
          pct_legacy: float_value(row, ["pct_legacy", "pctLegacy"]),
          site_count: integer_value(row, ["site_count", "siteCount"]) || 0,
          metadata: metadata(row, fleet_history_known_keys()),
          inserted_at: context.now,
          updated_at: context.now
        }
    end
  end

  defp fleet_history_attrs(_row, _context), do: nil

  defp upsert_source(attrs, _context) do
    replace_fields =
      [
        :plugin_source_id,
        :source_kind,
        :latest_collection_at,
        :metadata,
        :updated_at
      ] ++ reference_replace_fields(attrs)

    case Repo.insert_all("wifi_map_sources", [attrs],
           prefix: @prefix,
           on_conflict: {:replace, replace_fields},
           conflict_target: [:name],
           returning: [:source_id]
         ) do
      {_count, [%{source_id: source_id}]} -> {:ok, uuid_binary(source_id)}
      {_count, [%{"source_id" => source_id}]} -> {:ok, uuid_binary(source_id)}
      other -> {:error, {:unexpected_source_upsert_result, other}}
    end
  end

  defp reference_replace_fields(%{latest_reference_hash: value}) when is_binary(value),
    do: [:latest_reference_hash, :latest_reference_at]

  defp reference_replace_fields(_attrs), do: []

  defp upsert_batch(attrs, _context) do
    case Repo.insert_all("wifi_map_batches", [attrs],
           prefix: @prefix,
           on_conflict: {:replace, [:reference_hash, :source_files, :row_counts, :diagnostics]},
           conflict_target: [:source_id, :collection_timestamp, :collection_mode],
           returning: [:batch_id]
         ) do
      {_count, [%{batch_id: batch_id}]} -> {:ok, uuid_binary(batch_id)}
      {_count, [%{"batch_id" => batch_id}]} -> {:ok, uuid_binary(batch_id)}
      other -> {:error, {:unexpected_batch_upsert_result, other}}
    end
  end

  defp bulk_upsert([], _table, _conflict_target, _replace_fields, _context), do: :ok

  defp bulk_upsert(rows, table, conflict_target, replace_fields, _context) do
    table_name = Atom.to_string(table)

    rows
    |> unique_rows(conflict_target)
    |> Enum.chunk_every(bulk_chunk_size(rows))
    |> Enum.reduce_while(:ok, fn chunk, :ok ->
      case bulk_upsert_chunk(chunk, table_name, table, conflict_target, replace_fields) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp unique_rows(rows, conflict_target) do
    rows
    |> Enum.reverse()
    |> Enum.uniq_by(fn row -> Enum.map(conflict_target, &Map.get(row, &1)) end)
    |> Enum.reverse()
  end

  defp bulk_upsert_chunk(rows, table_name, table, conflict_target, replace_fields) do
    case Repo.insert_all(table_name, rows,
           prefix: @prefix,
           on_conflict: {:replace, replace_fields},
           conflict_target: conflict_target,
           returning: false
         ) do
      {_count, _rows} -> :ok
      other -> {:error, {:unexpected_bulk_upsert_result, table, other}}
    end
  end

  defp bulk_chunk_size([row | _rows]) when is_map(row) do
    field_count = row |> map_size() |> max(1)
    max(div(@max_insert_params, field_count), 1)
  end

  defp bulk_chunk_size(_rows), do: 1

  defp sync_device_inventory(updates, context) when is_list(updates) do
    SyncIngestor.ingest_updates(updates, actor: context.actor)
  end

  defp sync_devices([], _actor, _device_sync), do: :ok

  defp sync_devices(updates, actor, device_sync) do
    device_sync.(updates, %{actor: actor})
  end

  defp device_inventory_updates(body, status, source_attrs, collection_timestamp) do
    partition = partition_value(status)

    ap_updates =
      body
      |> device_rows([
        "access_points",
        "accessPoints",
        "aps",
        "ap_observations",
        "apObservations"
      ])
      |> Enum.map(
        &device_update_attrs(
          &1,
          :access_point,
          partition,
          source_attrs,
          collection_timestamp
        )
      )

    controller_updates =
      body
      |> controller_rows()
      |> Enum.map(
        &device_update_attrs(
          &1,
          :controller,
          partition,
          source_attrs,
          collection_timestamp
        )
      )

    (ap_updates ++ controller_updates)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq_by(fn update ->
      update["device_id"] || get_in(update, ["metadata", "integration_id"])
    end)
  end

  defp device_update_attrs(row, kind, partition, source_attrs, collection_timestamp)
       when is_map(row) do
    site_code = site_code(row)
    integration_id = wifi_integration_id(row, kind)

    device_id =
      explicit_sr_device_uid(row) || deterministic_wifi_device_uid(integration_id, partition)

    name = wifi_device_name(row, kind)

    if blank?(site_code) or blank?(integration_id) or blank?(name) do
      nil
    else
      observed_ip = wifi_observed_ip(row)

      %{
        "device_id" => device_id,
        "ip" => nil,
        "mac" =>
          normalize_mac(
            string_value(row, [
              "mac",
              "mac_address",
              "macAddress",
              "wired_mac",
              "wiredMac",
              "base_mac",
              "baseMac",
              "hw_base_mac",
              "hwBaseMac"
            ])
          ),
        "hostname" => name,
        "partition" => partition,
        "source" => "wifi_map",
        "is_available" => wifi_device_available?(row),
        "metadata" =>
          wifi_device_metadata(
            row,
            kind,
            site_code,
            integration_id,
            source_attrs,
            collection_timestamp,
            observed_ip
          ),
        "tags" => %{"wifi_map_site_code" => site_code}
      }
    end
  end

  defp device_update_attrs(_row, _kind, _partition, _source_attrs, _collection_timestamp), do: nil

  defp wifi_device_metadata(
         row,
         kind,
         site_code,
         integration_id,
         source_attrs,
         collection_timestamp,
         observed_ip
       ) do
    row_metadata = map_value(row, ["metadata"]) || %{}

    %{
      "integration_type" => "wifi_map",
      "integration_id" => integration_id,
      "wifi_map_asset_kind" => Atom.to_string(kind),
      "wifi_map_source_name" => source_attrs.name,
      "wifi_map_source_kind" => source_attrs.source_kind,
      "site_code" => site_code,
      "device_type" => wifi_device_type(kind),
      "device_role" => wifi_device_role(kind),
      "vendor_name" => string_value(row, ["vendor_name", "vendorName", "vendor"]) || "Aruba",
      "model" => string_value(row, ["model"]),
      "serial_number" =>
        string_value(row, [
          "serial",
          "serial_number",
          "serialNumber",
          "chassis_serial",
          "chassisSerial"
        ]),
      "status" => string_value(row, ["status"]),
      "collection_timestamp" => DateTime.to_iso8601(collection_timestamp)
    }
    |> maybe_put("observed_ip", observed_ip)
    |> maybe_put("aos_version", string_value(row, ["aos_version", "aosVersion", "version"]))
    |> maybe_put("aaa_profile", string_value(row, ["aaa_profile", "aaaProfile"]))
    |> maybe_put("server_group", string_value(row, ["server_group", "serverGroup"]))
    |> maybe_put("cluster", string_value(row, ["cluster", "server_group_location"]))
    |> Map.merge(stringify_map(row_metadata))
  end

  defp wifi_device_type(:access_point), do: "access_point"
  defp wifi_device_type(:controller), do: "switch"

  defp wifi_device_role(:access_point), do: "ap_bridge"
  defp wifi_device_role(:controller), do: "switch_l2"

  defp wifi_observed_ip(row) do
    string_value(row, ["ip", "ip_address", "ipAddress", "switch_ip", "switchIp"])
  end

  defp wifi_device_available?(row) do
    row
    |> string_value(["status"])
    |> case do
      nil -> true
      value -> String.downcase(value) in ["up", "ok", "online", "available", "true"]
    end
  end

  defp collection_timestamp(body, payload, status) do
    datetime_value(body, [
      "collection_timestamp",
      "collectionTimestamp",
      "observed_at",
      "observedAt"
    ]) ||
      datetime_value(payload, ["observed_at", "observedAt"]) ||
      FieldParser.parse_timestamp(status[:agent_timestamp] || status[:timestamp])
  end

  defp inferred_row_counts(body) do
    %{
      "sites" => length(list_value(body, ["sites"])),
      "site_references" =>
        length(list_value(body, ["site_references", "siteReferences", "airports", "references"])),
      "access_points" =>
        length(device_rows(body, ["access_points", "accessPoints", "aps", "ap_observations"])),
      "controllers" => length(controller_rows(body)),
      "radius_groups" => length(list_value(body, ["radius_groups", "radiusGroups"])),
      "fleet_history" => length(list_value(body, ["fleet_history", "fleetHistory", "history"]))
    }
  end

  defp device_rows(body, keys) do
    direct = list_value(body, keys)

    search_rows =
      body
      |> list_value(["search_index", "searchIndex", "devices", "assets"])
      |> Enum.filter(fn row ->
        row
        |> string_value(["kind", "type"])
        |> downcase()
        |> Kernel.in(["ap", "access_point", "access-point"])
      end)

    direct ++ search_rows
  end

  defp controller_rows(body) do
    direct =
      list_value(body, [
        "controllers",
        "controller_observations",
        "controllerObservations",
        "wlcs",
        "wlc_observations"
      ])

    search_rows =
      body
      |> list_value(["search_index", "searchIndex", "devices", "assets"])
      |> Enum.filter(fn row ->
        row
        |> string_value(["kind", "type"])
        |> downcase()
        |> Kernel.in(["controller", "wlc", "mobility_controller"])
      end)

    direct ++ search_rows
  end

  defp site_code(row) do
    row
    |> string_value(["site_code", "siteCode", "iata", "airport_code", "airportCode"])
    |> case do
      nil -> row |> string_value(["location"]) |> location_site_code()
      value -> value
    end
    |> case do
      nil -> nil
      value -> value |> String.trim() |> String.upcase()
    end
  end

  defp location_site_code(nil), do: nil

  defp location_site_code(value) do
    value = String.trim(value)

    cond do
      String.length(value) == 3 and String.match?(value, ~r/^[A-Za-z]{3}$/) ->
        value

      String.length(value) >= 4 and String.match?(String.slice(value, 1, 3), ~r/^[A-Za-z]{3}$/) ->
        String.slice(value, 1, 3)

      true ->
        value
    end
  end

  defp site_type(row) do
    row
    |> string_value(["site_type", "siteType", "type"])
    |> case do
      nil -> "airport"
      value -> value |> String.trim() |> String.downcase()
    end
  end

  defp wifi_device_uid(row, kind, context) do
    explicit_sr_device_uid(row) ||
      row
      |> wifi_integration_id(kind)
      |> deterministic_wifi_device_uid(context.partition)
  end

  defp explicit_sr_device_uid(row) do
    row
    |> string_value([
      "device_uid",
      "deviceUid",
      "canonical_device_id",
      "canonicalDeviceId",
      "uid"
    ])
    |> case do
      "sr:" <> _ = uid -> uid
      _ -> nil
    end
  end

  defp deterministic_wifi_device_uid(nil, _partition), do: nil

  defp deterministic_wifi_device_uid(integration_id, partition) do
    IdentityReconciler.generate_deterministic_device_id(%{
      agent_id: nil,
      armis_id: nil,
      integration_id: integration_id,
      netbox_id: nil,
      mac: nil,
      ip: nil,
      partition: partition
    })
  end

  defp wifi_integration_id(row, kind) do
    identity =
      first_present([
        string_value(row, ["device_uid", "deviceUid", "canonical_device_id", "canonicalDeviceId"]),
        string_value(row, [
          "serial",
          "serial_number",
          "serialNumber",
          "chassis_serial",
          "chassisSerial"
        ]),
        normalize_mac(
          string_value(row, [
            "mac",
            "mac_address",
            "macAddress",
            "wired_mac",
            "wiredMac",
            "base_mac",
            "baseMac",
            "hw_base_mac",
            "hwBaseMac"
          ])
        ),
        wifi_device_name(row, kind)
      ])

    case identity do
      nil -> nil
      value -> "wifi_map:#{kind}:#{value}"
    end
  end

  defp wifi_device_name(row, :access_point) do
    string_value(row, ["name", "ap_name", "apName", "hostname", "host"])
  end

  defp wifi_device_name(row, :controller) do
    string_value(row, [
      "name",
      "alias",
      "controller_alias",
      "controllerAlias",
      "device_alias",
      "deviceAlias",
      "hostname",
      "host",
      "expected_name",
      "expectedName"
    ])
  end

  defp partition_value(status) do
    status
    |> fetch_value(["partition"])
    |> string_value()
    |> case do
      nil -> "default"
      value -> value
    end
  end

  defp metadata(row, known_keys) do
    base = map_value(row, ["metadata"]) || %{}

    extra =
      Enum.reduce(row, %{}, fn {key, value}, acc ->
        key = to_string(key)

        if key in known_keys or is_nil(value) or value == "" do
          acc
        else
          Map.put(acc, key, value)
        end
      end)

    Map.merge(extra, stringify_map(base))
  end

  defp counter_map(row, keys) do
    case fetch_value(row, keys) do
      value when is_map(value) ->
        value
        |> stringify_map()
        |> Enum.reduce(%{}, fn {key, value}, acc ->
          Map.put(acc, key, integer_value(value) || 0)
        end)

      value when is_binary(value) ->
        value
        |> String.split(",", trim: true)
        |> Enum.reduce(%{}, fn part, acc ->
          case String.split(part, ":", parts: 2) do
            [key, count] ->
              Map.put(acc, String.trim(key), integer_value(count) || 0)

            _ ->
              acc
          end
        end)

      _ ->
        %{}
    end
  end

  defp string_list(row, keys) do
    case fetch_value(row, keys) do
      values when is_list(values) ->
        values
        |> Enum.map(&to_string/1)
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&blank?/1)

      value when is_binary(value) ->
        value
        |> String.split([";", ","], trim: true)
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&blank?/1)

      _ ->
        []
    end
  end

  defp map_value(map, keys) do
    case fetch_value(map, keys) do
      value when is_map(value) -> value
      _ -> nil
    end
  end

  defp list_value(map, keys) do
    case fetch_value(map, keys) do
      value when is_list(value) -> Enum.filter(value, &is_map/1)
      _ -> []
    end
  end

  defp fetch_value(map, keys) when is_map(map) and is_list(keys) do
    Enum.find_value(keys, fn key ->
      Map.get(map, key) || Map.get(map, to_string(key))
    end)
  end

  defp fetch_value(_map, _keys), do: nil

  defp string_value(map, keys) when is_map(map) and is_list(keys) do
    map
    |> fetch_value(keys)
    |> string_value()
  end

  defp string_value(value), do: value |> to_string_or_nil() |> reject_blank()

  defp integer_value(map, keys) when is_map(map), do: map |> fetch_value(keys) |> integer_value()
  defp integer_value(value) when is_integer(value), do: value
  defp integer_value(value) when is_float(value), do: trunc(value)

  defp integer_value(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, _} -> parsed
      :error -> nil
    end
  end

  defp integer_value(_value), do: nil

  defp float_value(map, keys) when is_map(map), do: map |> fetch_value(keys) |> float_value()
  defp float_value(value) when is_integer(value), do: value / 1
  defp float_value(value) when is_float(value), do: value

  defp float_value(value) when is_binary(value) do
    case Float.parse(String.trim(value)) do
      {parsed, _} -> parsed
      :error -> nil
    end
  end

  defp float_value(_value), do: nil

  defp datetime_value(map, keys) when is_map(map) do
    map
    |> fetch_value(keys)
    |> case do
      nil -> nil
      value -> value |> FieldParser.parse_timestamp() |> DateTime.truncate(:microsecond)
    end
  rescue
    _ -> nil
  end

  defp date_value(map, keys) do
    case fetch_value(map, keys) do
      %Date{} = date ->
        date

      %DateTime{} = datetime ->
        DateTime.to_date(datetime)

      value when is_binary(value) ->
        case Date.from_iso8601(String.trim(value)) do
          {:ok, date} -> date
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp uuid_value(map, keys) do
    value = string_value(map, keys)

    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> uuid
      :error -> nil
    end
  end

  defp uuid_binary_or_generate(nil), do: uuid_binary(Ecto.UUID.generate())
  defp uuid_binary_or_generate(value), do: uuid_binary(value) || uuid_binary(Ecto.UUID.generate())

  defp uuid_binary(nil), do: nil
  defp uuid_binary(value) when is_binary(value) and byte_size(value) == 16, do: value

  defp uuid_binary(value) when is_binary(value) do
    case Ecto.UUID.dump(value) do
      {:ok, binary} -> binary
      :error -> nil
    end
  end

  defp uuid_binary(_value), do: nil

  defp decode_json_map(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, decoded} when is_map(decoded) -> decoded
      _ -> nil
    end
  end

  defp decode_json_map(_value), do: nil

  defp stringify_map(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), value} end)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp first_present(values) do
    Enum.find(values, fn value -> not blank?(value) end)
  end

  defp normalize_mac(nil), do: nil
  defp normalize_mac(value), do: value |> String.trim() |> String.downcase()

  defp to_string_or_nil(nil), do: nil
  defp to_string_or_nil(value) when is_binary(value), do: String.trim(value)
  defp to_string_or_nil(value) when is_atom(value), do: Atom.to_string(value)
  defp to_string_or_nil(value) when is_integer(value), do: Integer.to_string(value)
  defp to_string_or_nil(value) when is_float(value), do: Float.to_string(value)
  defp to_string_or_nil(_value), do: nil

  defp reject_blank(nil), do: nil
  defp reject_blank(value) when is_binary(value), do: if(blank?(value), do: nil, else: value)

  defp blank?(nil), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_value), do: false

  defp downcase(nil), do: nil
  defp downcase(value), do: String.downcase(value)

  defp site_reference_known_keys do
    [
      "site_code",
      "siteCode",
      "iata",
      "airport_code",
      "airportCode",
      "name",
      "airport_name",
      "airportName",
      "site_type",
      "siteType",
      "type",
      "region",
      "lat",
      "latitude",
      "latitude_deg",
      "latitudeDeg",
      "lon",
      "lng",
      "longitude",
      "longitude_deg",
      "longitudeDeg",
      "reference_hash",
      "referenceHash",
      "metadata"
    ]
  end

  defp site_known_keys do
    site_reference_known_keys() ++ ["first_seen_at", "firstSeenAt", "last_seen_at", "lastSeenAt"]
  end

  defp site_snapshot_known_keys do
    site_known_keys() ++
      [
        "id",
        "collection_timestamp",
        "collectionTimestamp",
        "ap_count",
        "apCount",
        "up_count",
        "upCount",
        "down_count",
        "downCount",
        "models",
        "model_breakdown",
        "modelBreakdown",
        "controllers",
        "controller_names",
        "controllerNames",
        "wlc_count",
        "wlcCount",
        "wlcs",
        "wlc_model_breakdown",
        "wlcModelBreakdown",
        "aos_versions",
        "aos_version_breakdown",
        "aosVersionBreakdown",
        "server_group",
        "serverGroup",
        "cluster",
        "all_server_groups",
        "allServerGroups",
        "aaa_profile",
        "aaaProfile"
      ]
  end

  defp access_point_known_keys do
    [
      "id",
      "kind",
      "type",
      "device_uid",
      "deviceUid",
      "canonical_device_id",
      "canonicalDeviceId",
      "uid",
      "site_code",
      "siteCode",
      "iata",
      "airport_code",
      "airportCode",
      "location",
      "collection_timestamp",
      "collectionTimestamp",
      "name",
      "ap_name",
      "apName",
      "hostname",
      "host",
      "mac",
      "wired_mac",
      "wiredMac",
      "serial",
      "serial_number",
      "serialNumber",
      "ip",
      "ip_address",
      "ipAddress",
      "status",
      "model",
      "vendor_name",
      "vendorName",
      "vendor",
      "metadata"
    ]
  end

  defp controller_known_keys do
    access_point_known_keys() ++
      [
        "alias",
        "controller_alias",
        "controllerAlias",
        "device_alias",
        "deviceAlias",
        "expected_name",
        "expectedName",
        "mac_address",
        "macAddress",
        "base_mac",
        "baseMac",
        "hw_base_mac",
        "hwBaseMac",
        "chassis_serial",
        "chassisSerial",
        "switch_ip",
        "switchIp",
        "aos_version",
        "aosVersion",
        "version",
        "psu_status",
        "psuStatus",
        "uptime",
        "reboot_cause",
        "rebootCause"
      ]
  end

  defp radius_group_known_keys do
    [
      "id",
      "controller_device_uid",
      "controllerDeviceUid",
      "device_uid",
      "deviceUid",
      "site_code",
      "siteCode",
      "iata",
      "airport_code",
      "airportCode",
      "location",
      "collection_timestamp",
      "collectionTimestamp",
      "controller_alias",
      "controllerAlias",
      "device_alias",
      "deviceAlias",
      "alias",
      "name",
      "aaa_profile",
      "aaaProfile",
      "profile",
      "server_group",
      "serverGroup",
      "dot1x_server_group",
      "cluster",
      "server_group_location",
      "serverGroupLocation",
      "all_server_groups",
      "allServerGroups",
      "status",
      "metadata"
    ]
  end

  defp fleet_history_known_keys do
    [
      "build_date",
      "buildDate",
      "date",
      "ap_total",
      "apTotal",
      "count_2xx",
      "count2xx",
      "count_3xx",
      "count3xx",
      "count_4xx",
      "count4xx",
      "count_5xx",
      "count5xx",
      "count_6xx",
      "count6xx",
      "count_7xx",
      "count7xx",
      "count_other",
      "countOther",
      "count_ap325",
      "countAp325",
      "pct_6xx",
      "pct6xx",
      "pct_legacy",
      "pctLegacy",
      "site_count",
      "siteCount",
      "metadata"
    ]
  end
end
