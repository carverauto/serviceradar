defmodule ServiceRadar.Inventory.ProxmoxEnrichmentIngestor do
  @moduledoc """
  Ingests Proxmox plugin enrichment into provider-neutral virtualization inventory.
  """

  alias ServiceRadar.Inventory.HypervisorEnrichmentIngestor
  alias ServiceRadar.Inventory.IdentityReconciler
  alias ServiceRadar.Inventory.IntegrationIdentity

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
          |> HypervisorEnrichmentIngestor.merge_records()
          |> HypervisorEnrichmentIngestor.dedupe_records()

        persist =
          Keyword.get(opts, :persist, &HypervisorEnrichmentIngestor.persist_records(&1, opts))

        persist.(records)
    end
  end

  def ingest(payload, status, opts) when is_map(payload) do
    case details(payload) do
      %{"schema" => @schema} ->
        records =
          payload
          |> records_for_payload(status, opts)
          |> HypervisorEnrichmentIngestor.dedupe_records()

        persist =
          Keyword.get(opts, :persist, &HypervisorEnrichmentIngestor.persist_records(&1, opts))

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
    Enum.reduce(list(details["targets"]), HypervisorEnrichmentIngestor.empty_records(), fn target,
                                                                                           acc ->
      version = get_in(target, ["version", "version"])
      cluster = cluster_record(target, version, observed_at)
      cluster_ref = cluster && cluster.provider_ref
      cluster_scope = cluster_scope(target, cluster)

      acc =
        if cluster do
          put_record(acc, :clusters, cluster)
        else
          acc
        end

      target
      |> list_value("nodes")
      |> Enum.reduce(acc, fn node, acc ->
        add_node_records(acc, target, node, cluster_ref, cluster_scope, version, observed_at)
      end)
      |> add_guest_records(target, cluster_scope, observed_at)
    end)
  end

  # The v2 integration identity is cluster-scoped. Standalone (non-clustered)
  # nodes use the node name as the scope. When the cluster status fetch failed
  # we cannot tell those cases apart, so no v2 id is minted at all (the
  # provider_ref fallback applies) rather than risking a node-scoped id for a
  # clustered guest.
  defp cluster_scope(target, cluster) do
    cluster_name = cluster && cluster.name

    %{
      name: cluster_name,
      known?: not is_nil(cluster_name) or not cluster_status_failed?(target)
    }
  end

  defp cluster_status_failed?(target) do
    target
    |> map_value("warnings")
    |> Kernel.||(%{})
    |> string_value("cluster_status")
    |> present?()
  end

  defp scope_for(%{name: name}, _node_name) when is_binary(name) and name != "", do: name
  defp scope_for(%{known?: true}, node_name), do: node_name
  defp scope_for(_cluster_scope, _node_name), do: nil

  defp put_record(records, key, record), do: Map.update!(records, key, &[record | &1])

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

  defp add_node_records(records, target, node, cluster_ref, cluster_scope, version, observed_at) do
    node_name = string_value(node, "node")

    if blank?(node_name) do
      records
    else
      host_ref = "proxmox:node:#{node_name}"
      device_uid = device_uid_for_node(target, node_name)
      cluster_node = cluster_node_for(target, node_name)

      integration_id =
        IntegrationIdentity.proxmox_node_id(scope_for(cluster_scope, node_name), node_name)

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
        metadata:
          node
          |> node_metadata(cluster_node)
          |> maybe_put_metadata("integration_id", integration_id),
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

  defp add_guest_records(records, target, cluster_scope, observed_at) do
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

        integration_id =
          IntegrationIdentity.proxmox_guest_id(scope_for(cluster_scope, node), guest_type, vmid)

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
          metadata:
            guest
            |> Map.take(["id", "config", "runtime_status", "filesystems"])
            |> sanitize_metadata()
            |> maybe_put_metadata("integration_id", integration_id),
          observed_at: observed_at
        }

        acc
        |> put_record(:guests, record)
        |> add_guest_network_interface_records(
          guest,
          provider_ref,
          "proxmox:node:#{node}",
          target_partition(target),
          observed_at
        )
      end
    end)
  end

  defp add_guest_network_interface_records(
         records,
         guest,
         guest_ref,
         host_ref,
         partition,
         observed_at
       ) do
    guest
    |> list_value("interfaces")
    |> Enum.with_index()
    |> Enum.reduce(records, fn {iface, index}, acc ->
      name = string_value(iface, "name") || string_value(iface, "config_key") || "net#{index}"

      # Separator-free 12-hex via IdentityReconciler.normalize_mac, matching
      # the canonical MAC format used by the rest of the identity pipeline.
      mac_address = normalize_mac_identifier(string_value(iface, "mac_address"))
      ip_addresses = normalized_ip_addresses(iface)

      if blank?(name) and blank?(mac_address) and ip_addresses == [] do
        acc
      else
        key = mac_address || name || Integer.to_string(index)

        record = %{
          provider: @provider,
          provider_ref: "proxmox:guest-nic:#{guest_ref}:#{key}",
          host_provider_ref: host_ref,
          guest_provider_ref: guest_ref,
          device_uid: proxmox_guest_device_uid(guest),
          name: name,
          interface_type: string_value(iface, "model"),
          address: List.first(Enum.map(ip_addresses, &strip_cidr/1)),
          cidr: List.first(ip_addresses),
          bridge_ports: string_value(iface, "bridge"),
          vlan_id: integer_value(iface, "vlan_id"),
          mac_address: mac_address,
          ip_addresses: ip_addresses,
          source: string_value(iface, "source"),
          metadata: iface |> sanitize_metadata() |> maybe_put_metadata("partition", partition),
          observed_at: observed_at
        }

        put_record(acc, :network_interfaces, record)
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

      mac_address =
        normalize_mac_identifier(
          string_value(iface, "mac_address") || string_value(iface, "hwaddr")
        )

      ip_addresses = normalized_host_ip_addresses(iface)

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
          mac_address: mac_address,
          ip_addresses: ip_addresses,
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

  defp node_metadata(node, cluster_node) do
    %{}
    |> maybe_put_metadata("runtime_status", map_value(node, "runtime_status"))
    |> maybe_put_metadata("ip", string_value(node, "ip") || string_value(cluster_node, "ip"))
    |> maybe_put_metadata("cluster_node", cluster_node)
    |> sanitize_metadata()
  end

  defp cluster_node_for(target, node_name) do
    target
    |> list_value("cluster")
    |> Enum.find(fn entry ->
      string_value(entry, "type") == "node" and
        same_host_or_node?(cluster_node_name(entry), node_name)
    end)
  end

  defp cluster_node_name(entry) do
    string_value(entry, "name") ||
      entry |> string_value("id") |> strip_cluster_node_prefix()
  end

  defp strip_cluster_node_prefix("node/" <> name), do: name
  defp strip_cluster_node_prefix(value), do: value

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

  defp target_partition(target) do
    target
    |> map_value("metadata")
    |> string_value("partition")
    |> Kernel.||("default")
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

  defp normalized_ip_addresses(iface) do
    iface
    |> list_string_value("ip_addresses")
    |> Enum.map(&normalize_ip_cidr/1)
    |> Enum.filter(&present?/1)
    |> Enum.uniq()
  end

  defp normalized_host_ip_addresses(iface) do
    (list_string_value(iface, "ip_addresses") ++
       [string_value(iface, "cidr"), string_value(iface, "address")])
    |> Enum.map(&normalize_ip_cidr/1)
    |> Enum.filter(&present?/1)
    |> Enum.uniq()
  end

  defp list_string_value(map, key) when is_map(map) do
    case field_value(map, key) do
      value when is_list(value) ->
        value
        |> Enum.map(&stringify_scalar/1)
        |> Enum.map(&String.trim/1)
        |> Enum.filter(&present?/1)

      value when is_binary(value) ->
        value
        |> String.split([",", " "], trim: true)
        |> Enum.map(&String.trim/1)
        |> Enum.filter(&present?/1)

      _ ->
        []
    end
  end

  defp list_string_value(_map, _key), do: []

  defp stringify_scalar(value) when is_binary(value), do: value
  defp stringify_scalar(value) when is_integer(value), do: Integer.to_string(value)
  defp stringify_scalar(value) when is_float(value), do: Float.to_string(value)
  defp stringify_scalar(_value), do: ""

  defp normalize_mac_identifier(value) when is_binary(value) do
    case IdentityReconciler.normalize_mac(value) do
      normalized when is_binary(normalized) and byte_size(normalized) == 12 -> normalized
      _ -> nil
    end
  end

  defp normalize_mac_identifier(_value), do: nil

  defp normalize_ip_cidr(value) when is_binary(value) do
    value = String.trim(value)

    case String.downcase(value) do
      "" -> nil
      "dhcp" -> nil
      "auto" -> nil
      "manual" -> nil
      "none" -> nil
      _ -> value
    end
  end

  defp normalize_ip_cidr(_value), do: nil

  defp strip_cidr(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.split("/", parts: 2)
    |> List.first()
    |> blank_to_nil()
  end

  defp strip_cidr(_value), do: nil

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

  defp maybe_put_metadata(metadata, _key, value) when value in [nil, ""], do: metadata

  defp maybe_put_metadata(metadata, key, value) when is_map(metadata),
    do: Map.put(metadata, key, value)

  defp maybe_put_metadata(_metadata, key, value), do: %{key => value}

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
