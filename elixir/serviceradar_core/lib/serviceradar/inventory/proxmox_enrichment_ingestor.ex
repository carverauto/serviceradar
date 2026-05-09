defmodule ServiceRadar.Inventory.ProxmoxEnrichmentIngestor do
  @moduledoc """
  Ingests Proxmox plugin enrichment into provider-neutral virtualization inventory.
  """

  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Inventory.VirtualizationCluster
  alias ServiceRadar.Inventory.VirtualizationDatastore
  alias ServiceRadar.Inventory.VirtualizationGuest
  alias ServiceRadar.Inventory.VirtualizationHost
  alias ServiceRadar.Inventory.VirtualizationHostDisk
  alias ServiceRadar.Inventory.VirtualizationNetworkInterface
  alias ServiceRadar.Inventory.VirtualizationStorageSystem

  require Ash.Query
  require Logger

  @provider "proxmox"
  @schema "serviceradar.proxmox_enrichment.v1"

  @spec supports?(map() | list(), map()) :: boolean()
  def supports?(payload, status \\ %{})

  def supports?(payload, status) when is_list(payload) do
    Enum.any?(payload, &supports?(&1, status))
  end

  def supports?(payload, _status) when is_map(payload) do
    case details(payload) do
      %{"schema" => @schema} -> true
      _ -> false
    end
  end

  def supports?(_payload, _status), do: false

  @spec ingest(map() | list(), map(), keyword()) :: :ok | {:error, term()}
  def ingest(payload, status, opts \\ [])

  def ingest(payload, status, opts) when is_list(payload) do
    payload
    |> Enum.filter(&supports?(&1, status))
    |> case do
      [] ->
        :ok

      entries ->
        records =
          entries
          |> Enum.map(&records_for_payload(&1, status, opts))
          |> merge_records()
          |> dedupe_records()

        persist = Keyword.get(opts, :persist, &persist_records(&1, opts))
        persist.(records)
    end
  end

  def ingest(payload, status, opts) when is_map(payload) do
    case details(payload) do
      %{"schema" => @schema} ->
        records =
          payload
          |> records_for_payload(status, opts)
          |> dedupe_records()

        persist = Keyword.get(opts, :persist, &persist_records(&1, opts))
        persist.(records)

      _ ->
        :ok
    end
  rescue
    e ->
      Logger.warning("Proxmox enrichment ingest failed: #{Exception.message(e)}")
      {:error, e}
  end

  def ingest(_payload, _status, _opts), do: :ok

  defp details(%{"details" => raw}) when is_binary(raw) do
    case Jason.decode(raw) do
      {:ok, decoded} when is_map(decoded) -> decoded
      _ -> nil
    end
  end

  defp details(%{"details" => raw}) when is_map(raw), do: raw
  defp details(_payload), do: nil

  defp records_for_payload(payload, status, opts) do
    payload
    |> details()
    |> build_records(Keyword.get(opts, :observed_at) || observed_at(payload, status))
  end

  defp observed_at(payload, status) do
    parse_time(
      payload["observed_at"] || payload["observedAt"] || status[:agent_timestamp] ||
        status[:timestamp]
    ) ||
      DateTime.utc_now()
  end

  defp parse_time(%DateTime{} = value), do: value

  defp parse_time(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, parsed, _offset} -> DateTime.truncate(parsed, :microsecond)
      _ -> nil
    end
  end

  defp parse_time(_value), do: nil

  defp build_records(details, observed_at) do
    Enum.reduce(list(details["targets"]), empty_records(), fn target, acc ->
      version = get_in(target, ["version", "version"])
      cluster = cluster_record(target, version, observed_at)
      cluster_ref = cluster && cluster.provider_ref

      acc =
        if cluster do
          put_record(acc, :clusters, cluster)
        else
          acc
        end

      target
      |> list_value("nodes")
      |> Enum.reduce(acc, fn node, acc ->
        add_node_records(acc, target, node, cluster_ref, version, observed_at)
      end)
      |> add_guest_records(target, observed_at)
    end)
  end

  defp empty_records do
    %{
      clusters: [],
      hosts: [],
      guests: [],
      datastores: [],
      host_disks: [],
      network_interfaces: [],
      storage_systems: []
    }
  end

  defp put_record(records, key, record), do: Map.update!(records, key, &[record | &1])

  defp merge_records(record_sets) do
    Enum.reduce(record_sets, empty_records(), fn records, acc ->
      Map.new(acc, fn {key, values} -> {key, values ++ Map.fetch!(records, key)} end)
    end)
  end

  defp dedupe_records(records) do
    Map.new(records, fn {key, values} ->
      {key, dedupe_provider_refs(values)}
    end)
  end

  defp dedupe_provider_refs(records) do
    records
    |> Enum.reduce(%{}, fn record, acc ->
      key = {record.provider, record.provider_ref}

      Map.update(acc, key, record, fn current ->
        if newer_record?(record, current), do: record, else: current
      end)
    end)
    |> Map.values()
  end

  defp newer_record?(candidate, current) do
    case {candidate[:observed_at], current[:observed_at]} do
      {%DateTime{} = left, %DateTime{} = right} -> DateTime.compare(left, right) != :lt
      {%DateTime{}, _} -> true
      {_, nil} -> true
      _ -> true
    end
  end

  defp cluster_record(target, version, observed_at) do
    cluster =
      target
      |> list_value("cluster")
      |> Enum.find(&(string_value(&1, "type") == "cluster"))

    if cluster do
      name = string_value(cluster, "name") || string_value(cluster, "id") || "proxmox"

      %{
        provider: @provider,
        provider_ref: "proxmox:cluster:#{name}",
        name: name,
        status: cluster_status(cluster),
        version: version,
        metadata: sanitize_metadata(cluster),
        observed_at: observed_at
      }
    end
  end

  defp add_node_records(records, target, node, cluster_ref, version, observed_at) do
    node_name = string_value(node, "node")

    if blank?(node_name) do
      records
    else
      host_ref = "proxmox:node:#{node_name}"
      device_uid = device_uid_for_node(target, node_name)

      host = %{
        provider: @provider,
        provider_ref: host_ref,
        cluster_provider_ref: cluster_ref,
        device_uid: device_uid,
        name: node_name,
        status: string_value(node, "status"),
        version: version,
        cpu_ratio: number_value(node, "cpu"),
        memory_used_bytes: integer_value(node, "mem"),
        memory_total_bytes: integer_value(node, "maxmem"),
        uptime_seconds: integer_value(node, "uptime"),
        metadata: sanitize_metadata(Map.take(node, ["runtime_status"])),
        observed_at: observed_at
      }

      records
      |> put_record(:hosts, host)
      |> add_datastore_records(node, cluster_ref, host_ref, observed_at)
      |> add_host_disk_records(node, host_ref, device_uid, observed_at)
      |> add_network_interface_records(node, host_ref, device_uid, observed_at)
      |> add_ceph_record(node, cluster_ref, host_ref, observed_at)
    end
  end

  defp add_guest_records(records, target, observed_at) do
    target
    |> list_value("guests")
    |> Enum.reduce(records, fn guest, acc ->
      node = string_value(guest, "node")
      guest_type = string_value(guest, "type") || "guest"
      vmid = integer_value(guest, "vmid")

      if blank?(node) or is_nil(vmid) do
        acc
      else
        provider_ref = "proxmox:guest:#{node}:#{guest_type}:#{vmid}"

        record = %{
          provider: @provider,
          provider_ref: provider_ref,
          host_provider_ref: "proxmox:node:#{node}",
          device_uid: proxmox_guest_device_uid(guest),
          name: string_value(guest, "name") || Integer.to_string(vmid),
          guest_type: proxmox_guest_type(guest_type),
          vmid: vmid,
          status: string_value(guest, "status"),
          cpu_ratio: number_value(guest, "cpu"),
          memory_used_bytes: integer_value(guest, "mem"),
          memory_total_bytes: integer_value(guest, "maxmem"),
          disk_used_bytes: integer_value(guest, "disk"),
          disk_total_bytes: integer_value(guest, "maxdisk"),
          uptime_seconds: integer_value(guest, "uptime"),
          metadata: sanitize_metadata(Map.take(guest, ["id", "config", "runtime_status"])),
          observed_at: observed_at
        }

        put_record(acc, :guests, record)
      end
    end)
  end

  defp add_datastore_records(records, node, cluster_ref, host_ref, observed_at) do
    node
    |> list_value("storage")
    |> Enum.reduce(records, fn storage, acc ->
      name = string_value(storage, "storage")

      if blank?(name) do
        acc
      else
        record = %{
          provider: @provider,
          provider_ref: "proxmox:datastore:#{string_value(node, "node")}:#{name}",
          cluster_provider_ref: cluster_ref,
          host_provider_ref: host_ref,
          name: name,
          storage_type: string_value(storage, "type"),
          content: string_value(storage, "content"),
          active: bool_value(storage, "active"),
          enabled: bool_value(storage, "enabled"),
          shared: bool_value(storage, "shared"),
          used_bytes: integer_value(storage, "used"),
          available_bytes: integer_value(storage, "avail"),
          total_bytes: integer_value(storage, "total"),
          metadata: sanitize_metadata(storage),
          observed_at: observed_at
        }

        put_record(acc, :datastores, record)
      end
    end)
  end

  defp add_host_disk_records(records, node, host_ref, device_uid, observed_at) do
    node
    |> list_value("disks")
    |> Enum.reduce(records, fn disk, acc ->
      disk_ref =
        string_value(disk, "devpath") || string_value(disk, "by_id_link") ||
          string_value(disk, "model")

      if blank?(disk_ref) do
        acc
      else
        record = %{
          provider: @provider,
          provider_ref: "proxmox:disk:#{string_value(node, "node")}:#{disk_ref}",
          host_provider_ref: host_ref,
          device_uid: device_uid,
          path: string_value(disk, "devpath"),
          by_id: string_value(disk, "by_id_link"),
          disk_type: string_value(disk, "type"),
          vendor: string_value(disk, "vendor"),
          model: string_value(disk, "model"),
          health: string_value(disk, "health"),
          size_bytes: integer_value(disk, "size"),
          wearout: integer_value(disk, "wearout"),
          usage: string_value(disk, "used"),
          metadata: sanitize_metadata(disk),
          observed_at: observed_at
        }

        put_record(acc, :host_disks, record)
      end
    end)
  end

  defp add_network_interface_records(records, node, host_ref, device_uid, observed_at) do
    node
    |> list_value("network")
    |> Enum.reduce(records, fn iface, acc ->
      name = string_value(iface, "iface")

      if blank?(name) do
        acc
      else
        record = %{
          provider: @provider,
          provider_ref: "proxmox:nic:#{string_value(node, "node")}:#{name}",
          host_provider_ref: host_ref,
          device_uid: device_uid,
          name: name,
          interface_type: string_value(iface, "type"),
          active: bool_value(iface, "active"),
          exists: bool_value(iface, "exists"),
          method: string_value(iface, "method"),
          method6: string_value(iface, "method6"),
          address: string_value(iface, "address"),
          cidr: string_value(iface, "cidr"),
          gateway: string_value(iface, "gateway"),
          bridge_ports: string_value(iface, "bridge-ports"),
          vlan_id: integer_value(iface, "vlan-id"),
          metadata: sanitize_metadata(iface),
          observed_at: observed_at
        }

        put_record(acc, :network_interfaces, record)
      end
    end)
  end

  defp add_ceph_record(records, node, cluster_ref, host_ref, observed_at) do
    case map_value(node, "ceph") do
      nil ->
        records

      ceph ->
        record = %{
          provider: @provider,
          provider_ref: "proxmox:ceph:#{string_value(node, "node")}",
          cluster_provider_ref: cluster_ref,
          host_provider_ref: host_ref,
          name: "Ceph",
          storage_system_type: "ceph",
          health: string_value(ceph, "health"),
          status: string_value(ceph, "health"),
          metadata: sanitize_metadata(ceph),
          observed_at: observed_at
        }

        put_record(records, :storage_systems, record)
    end
  end

  defp persist_records(records, opts) do
    actor = Keyword.fetch!(opts, :actor)
    records = resolve_existing_device_uids(records, actor)

    with {:ok, cluster_ids} <- upsert_group(VirtualizationCluster, records.clusters, actor),
         host_rows = link_refs(records.hosts, cluster_ids, %{}),
         {:ok, host_ids} <- upsert_group(VirtualizationHost, host_rows, actor),
         datastores = link_refs(records.datastores, cluster_ids, host_ids),
         disks = link_refs(records.host_disks, %{}, host_ids),
         nics = link_refs(records.network_interfaces, %{}, host_ids),
         guests = link_refs(records.guests, %{}, host_ids),
         storage_systems = link_refs(records.storage_systems, cluster_ids, host_ids),
         {:ok, _} <- upsert_group(VirtualizationDatastore, datastores, actor),
         {:ok, _} <- upsert_group(VirtualizationHostDisk, disks, actor),
         {:ok, _} <- upsert_group(VirtualizationNetworkInterface, nics, actor),
         {:ok, _} <- upsert_group(VirtualizationGuest, guests, actor),
         {:ok, _} <- upsert_group(VirtualizationStorageSystem, storage_systems, actor) do
      :ok
    end
  end

  defp resolve_existing_device_uids(records, actor) do
    candidates =
      records.hosts ++ records.guests ++ records.host_disks ++ records.network_interfaces

    current_uids =
      candidates
      |> Enum.map(&Map.get(&1, :device_uid))
      |> Enum.filter(&present?/1)

    names =
      candidates
      |> Enum.flat_map(fn record ->
        [Map.get(record, :name), node_name_from_provider_ref(Map.get(record, :provider_ref))]
      end)
      |> Enum.filter(&present?/1)

    devices = lookup_devices(current_uids, names, actor)

    Map.merge(records, %{
      hosts: Enum.map(records.hosts, &resolve_record_device_uid(&1, devices)),
      guests: Enum.map(records.guests, &resolve_record_device_uid(&1, devices)),
      host_disks: Enum.map(records.host_disks, &resolve_record_device_uid(&1, devices)),
      network_interfaces:
        Enum.map(records.network_interfaces, &resolve_record_device_uid(&1, devices))
    })
  end

  defp lookup_devices([], [], _actor), do: %{by_uid: %{}, by_name: %{}}

  defp lookup_devices(uids, names, actor) do
    uids = Enum.uniq(uids)
    names = Enum.uniq(names)
    names_downcase = Enum.map(names, &String.downcase/1)

    Device
    |> Ash.Query.for_read(:read, %{include_deleted: false})
    |> Ash.Query.filter(
      uid in ^uids or fragment("lower(?)", name) in ^names_downcase or
        fragment("lower(?)", hostname) in ^names_downcase
    )
    |> Ash.read(actor: actor)
    |> unwrap_page()
    |> case do
      {:ok, devices} ->
        %{
          by_uid: Map.new(devices, &{&1.uid, &1.uid}),
          by_name:
            devices
            |> Enum.flat_map(fn device ->
              [
                {normalize_lookup_key(device.name), device.uid},
                {normalize_lookup_key(device.hostname), device.uid}
              ]
            end)
            |> Enum.reject(fn {key, _uid} -> is_nil(key) end)
            |> Map.new()
        }

      {:error, reason} ->
        Logger.warning("Proxmox enrichment device lookup failed: #{inspect(reason)}")
        %{by_uid: %{}, by_name: %{}}
    end
  end

  defp unwrap_page({:ok, %Ash.Page.Keyset{results: results}}), do: {:ok, results}
  defp unwrap_page({:ok, %Ash.Page.Offset{results: results}}), do: {:ok, results}
  defp unwrap_page({:ok, results}) when is_list(results), do: {:ok, results}
  defp unwrap_page(other), do: other

  defp resolve_record_device_uid(record, devices) do
    current_uid = Map.get(record, :device_uid)

    resolved =
      Map.get(devices.by_uid, current_uid) ||
        lookup_device_by_record_name(record, devices) ||
        existing_sr_uid(current_uid)

    Map.put(record, :device_uid, resolved)
  end

  defp lookup_device_by_record_name(record, devices) do
    Enum.find_value(
      [
        Map.get(record, :name),
        node_name_from_provider_ref(Map.get(record, :provider_ref))
      ],
      fn value ->
        Map.get(devices.by_name, normalize_lookup_key(value))
      end
    )
  end

  defp existing_sr_uid(value) when is_binary(value) do
    if String.starts_with?(value, "sr:"), do: value
  end

  defp existing_sr_uid(_value), do: nil

  defp node_name_from_provider_ref("proxmox:node:" <> node), do: node

  defp node_name_from_provider_ref("proxmox:disk:" <> rest),
    do: rest |> String.split(":") |> List.first()

  defp node_name_from_provider_ref("proxmox:nic:" <> rest),
    do: rest |> String.split(":") |> List.first()

  defp node_name_from_provider_ref("proxmox:guest:" <> rest),
    do: rest |> String.split(":") |> List.first()

  defp node_name_from_provider_ref(_value), do: nil

  defp normalize_lookup_key(value) when is_binary(value) do
    value
    |> String.downcase()
    |> String.trim()
    |> blank_to_nil()
  end

  defp normalize_lookup_key(_value), do: nil

  defp upsert_group(_resource, [], _actor), do: {:ok, %{}}

  defp upsert_group(resource, rows, actor) do
    rows =
      rows
      |> Enum.map(&strip_ref_helpers/1)
      |> Enum.uniq_by(&{&1.provider, &1.provider_ref})

    case Ash.bulk_create(rows, resource, :create,
           actor: actor,
           domain: ServiceRadar.Inventory,
           return_records?: true,
           return_errors?: true,
           stop_on_error?: false,
           upsert?: true,
           upsert_identity: :unique_provider_ref,
           upsert_fields: upsert_fields(resource)
         ) do
      %Ash.BulkResult{status: :success, records: records} ->
        {:ok, Map.new(records, &{&1.provider_ref, &1.id})}

      %Ash.BulkResult{errors: errors} = result ->
        {:error, errors || result}
    end
  end

  defp upsert_fields(VirtualizationCluster),
    do: [:name, :status, :version, :metadata, :observed_at, :updated_at]

  defp upsert_fields(VirtualizationHost) do
    [
      :cluster_id,
      :device_uid,
      :name,
      :status,
      :version,
      :cpu_ratio,
      :memory_used_bytes,
      :memory_total_bytes,
      :uptime_seconds,
      :metadata,
      :observed_at,
      :updated_at
    ]
  end

  defp upsert_fields(VirtualizationGuest) do
    [
      :host_id,
      :device_uid,
      :name,
      :guest_type,
      :vmid,
      :status,
      :cpu_ratio,
      :memory_used_bytes,
      :memory_total_bytes,
      :disk_used_bytes,
      :disk_total_bytes,
      :uptime_seconds,
      :metadata,
      :observed_at,
      :updated_at
    ]
  end

  defp upsert_fields(VirtualizationDatastore) do
    [
      :cluster_id,
      :host_id,
      :name,
      :storage_type,
      :content,
      :active,
      :enabled,
      :shared,
      :used_bytes,
      :available_bytes,
      :total_bytes,
      :metadata,
      :observed_at,
      :updated_at
    ]
  end

  defp upsert_fields(VirtualizationHostDisk) do
    [
      :host_id,
      :device_uid,
      :path,
      :by_id,
      :disk_type,
      :vendor,
      :model,
      :health,
      :size_bytes,
      :wearout,
      :usage,
      :metadata,
      :observed_at,
      :updated_at
    ]
  end

  defp upsert_fields(VirtualizationNetworkInterface) do
    [
      :host_id,
      :device_uid,
      :name,
      :interface_type,
      :active,
      :exists,
      :method,
      :method6,
      :address,
      :cidr,
      :gateway,
      :bridge_ports,
      :vlan_id,
      :metadata,
      :observed_at,
      :updated_at
    ]
  end

  defp upsert_fields(VirtualizationStorageSystem) do
    [
      :cluster_id,
      :host_id,
      :name,
      :storage_system_type,
      :health,
      :status,
      :metadata,
      :observed_at,
      :updated_at
    ]
  end

  defp link_refs(rows, cluster_ids, host_ids) do
    Enum.map(rows, fn row ->
      row
      |> maybe_link_ref(:cluster_provider_ref, :cluster_id, cluster_ids)
      |> maybe_link_ref(:host_provider_ref, :host_id, host_ids)
    end)
  end

  defp maybe_link_ref(row, ref_key, id_key, id_map) do
    case Map.get(row, ref_key) do
      ref when is_binary(ref) -> Map.put(row, id_key, Map.get(id_map, ref))
      _ -> row
    end
  end

  defp strip_ref_helpers(row) do
    Map.drop(row, [:cluster_provider_ref, :host_provider_ref])
  end

  defp device_uid_for_node(target, node_name) do
    meta = map_value(target, "metadata") || %{}
    target_device_id = string_value(meta, "device_id")

    target_hostname =
      string_value(meta, "hostname") || host_from_url(string_value(target, "base_url"))

    if same_host_or_node?(target_hostname, node_name) do
      target_device_id || "proxmox:pve:#{node_name}"
    else
      "proxmox:pve:#{node_name}"
    end
  end

  defp proxmox_guest_device_uid(guest) do
    case string_value(guest, "id") do
      value when is_binary(value) and value != "" ->
        "proxmox:" <> String.replace(value, "/", ":")

      _ ->
        "proxmox:#{proxmox_guest_type(string_value(guest, "type"))}:#{integer_value(guest, "vmid")}"
    end
  end

  defp proxmox_guest_type("qemu"), do: "vm"
  defp proxmox_guest_type("lxc"), do: "container"
  defp proxmox_guest_type(value) when is_binary(value) and value != "", do: value
  defp proxmox_guest_type(_), do: "guest"

  defp cluster_status(cluster) do
    case integer_value(cluster, "quorate") do
      1 -> "quorate"
      0 -> "not_quorate"
      _ -> nil
    end
  end

  defp host_from_url(raw) do
    case URI.parse(to_string(raw)) do
      %URI{host: host} when is_binary(host) -> host
      _ -> nil
    end
  end

  defp same_host_or_node?(candidate, node) do
    candidate = candidate |> to_string() |> String.downcase() |> String.trim()
    node = node |> to_string() |> String.downcase() |> String.trim()

    candidate != "" and node != "" and
      (candidate == node or candidate |> String.split(".") |> List.first() == node)
  end

  defp list_value(map, key) when is_map(map), do: map |> field_value(key) |> list()
  defp list_value(_map, _key), do: []

  defp list(values) when is_list(values), do: Enum.filter(values, &is_map/1)
  defp list(_values), do: []

  defp map_value(map, key) when is_map(map) do
    case field_value(map, key) do
      value when is_map(value) -> value
      _ -> nil
    end
  end

  defp map_value(_map, _key), do: nil

  defp string_value(map, key) when is_map(map) do
    case field_value(map, key) do
      value when is_binary(value) -> value |> String.trim() |> blank_to_nil()
      value when is_integer(value) -> Integer.to_string(value)
      value when is_float(value) -> Float.to_string(value)
      _ -> nil
    end
  end

  defp string_value(_map, _key), do: nil

  defp number_value(map, key) when is_map(map) do
    case field_value(map, key) do
      value when is_integer(value) -> value / 1
      value when is_float(value) -> value
      value when is_binary(value) -> parse_float(value)
      _ -> nil
    end
  end

  defp number_value(_map, _key), do: nil

  defp integer_value(map, key) do
    case number_value(map, key) do
      value when is_number(value) -> trunc(value)
      _ -> nil
    end
  end

  defp bool_value(map, key) when is_map(map) do
    case field_value(map, key) do
      value when is_boolean(value) ->
        value

      value when is_integer(value) ->
        value != 0

      value when is_float(value) ->
        value != 0.0

      value when is_binary(value) ->
        String.downcase(String.trim(value)) in ["1", "true", "yes", "on"]

      _ ->
        nil
    end
  end

  defp bool_value(_map, _key), do: nil

  defp field_value(map, key) do
    string_key = to_string(key)

    cond do
      Map.has_key?(map, key) -> Map.get(map, key)
      Map.has_key?(map, string_key) -> Map.get(map, string_key)
      true -> nil
    end
  end

  defp parse_float(value) do
    case Float.parse(String.trim(value)) do
      {parsed, _} -> parsed
      :error -> nil
    end
  end

  defp sanitize_metadata(value) when is_map(value) do
    Enum.reduce(value, %{}, fn {key, raw_value}, acc ->
      key = to_string(key)

      if sensitive_key?(key) do
        acc
      else
        Map.put(acc, key, sanitize_metadata(raw_value))
      end
    end)
  end

  defp sanitize_metadata(value) when is_list(value), do: Enum.map(value, &sanitize_metadata/1)

  defp sanitize_metadata(value) when is_binary(value) do
    if String.contains?(value, "PVEAPIToken="), do: "REDACTED", else: value
  end

  defp sanitize_metadata(value), do: value

  defp sensitive_key?(key) do
    normalized = String.downcase(String.trim(key))

    Enum.any?(
      [
        "password",
        "passwd",
        "secret",
        "token",
        "credential",
        "apikey",
        "api_key",
        "privatekey",
        "private_key"
      ],
      &String.contains?(normalized, &1)
    )
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value
  defp blank?(value), do: value in [nil, ""]
  defp present?(value), do: not blank?(value)
end
