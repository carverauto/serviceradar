defmodule ServiceRadar.Inventory.HypervisorEnrichmentIngestor do
  @moduledoc """
  Ingests provider-neutral hypervisor enrichment records into virtualization inventory.

  Provider-specific collectors should normalize API-native shapes into this
  shared record set before persistence. Proxmox currently adapts its legacy
  payload into these records; future vSphere/vCenter support should emit this
  envelope directly.
  """

  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Inventory.DeviceIdentifier
  alias ServiceRadar.Inventory.IdentityReconciler
  alias ServiceRadar.Inventory.VirtualizationCluster
  alias ServiceRadar.Inventory.VirtualizationDatastore
  alias ServiceRadar.Inventory.VirtualizationGuest
  alias ServiceRadar.Inventory.VirtualizationHost
  alias ServiceRadar.Inventory.VirtualizationHostDisk
  alias ServiceRadar.Inventory.VirtualizationNetworkInterface
  alias ServiceRadar.Inventory.VirtualizationStorageSystem

  require Ash.Query
  require Logger

  @schema "serviceradar.hypervisor_enrichment.v1"

  @record_keys [
    :clusters,
    :hosts,
    :guests,
    :datastores,
    :host_disks,
    :network_interfaces,
    :storage_systems,
    :console_targets
  ]

  @record_sources %{
    clusters: ["clusters"],
    hosts: ["hosts"],
    guests: ["guests"],
    datastores: ["datastores"],
    host_disks: ["host_disks", "disks"],
    network_interfaces: ["network_interfaces", "guest_network_interfaces"],
    storage_systems: ["storage_systems"],
    console_targets: ["console_targets"]
  }

  @field_allowlist %{
    clusters: [
      :provider,
      :provider_ref,
      :name,
      :status,
      :version,
      :metadata,
      :observed_at
    ],
    hosts: [
      :provider,
      :provider_ref,
      :cluster_provider_ref,
      :device_uid,
      :name,
      :status,
      :version,
      :cpu_ratio,
      :memory_used_bytes,
      :memory_total_bytes,
      :uptime_seconds,
      :metadata,
      :observed_at
    ],
    guests: [
      :provider,
      :provider_ref,
      :host_provider_ref,
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
      :observed_at
    ],
    datastores: [
      :provider,
      :provider_ref,
      :cluster_provider_ref,
      :host_provider_ref,
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
      :observed_at
    ],
    host_disks: [
      :provider,
      :provider_ref,
      :host_provider_ref,
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
      :observed_at
    ],
    network_interfaces: [
      :provider,
      :provider_ref,
      :host_provider_ref,
      :guest_provider_ref,
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
      :mac_address,
      :ip_addresses,
      :source,
      :metadata,
      :observed_at
    ],
    storage_systems: [
      :provider,
      :provider_ref,
      :cluster_provider_ref,
      :host_provider_ref,
      :name,
      :storage_system_type,
      :health,
      :status,
      :metadata,
      :observed_at
    ],
    console_targets: [
      :provider,
      :provider_ref,
      :target_ref,
      :target_type,
      :protocol,
      :transport,
      :credential_purpose,
      :agent_id,
      :capabilities,
      :device_uid,
      :metadata,
      :observed_at
    ]
  }
  @field_by_name @field_allowlist
                 |> Map.values()
                 |> List.flatten()
                 |> Enum.uniq()
                 |> Map.new(&{Atom.to_string(&1), &1})

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
      Logger.warning("Hypervisor enrichment ingest failed: #{Exception.message(e)}")
      {:error, e}
  end

  def ingest(_payload, _status, _opts), do: :ok

  def empty_records do
    %{
      clusters: [],
      hosts: [],
      guests: [],
      datastores: [],
      host_disks: [],
      network_interfaces: [],
      storage_systems: [],
      console_targets: []
    }
  end

  def merge_records(record_sets) do
    Enum.reduce(record_sets, empty_records(), fn records, acc ->
      Map.new(acc, fn {key, values} -> {key, values ++ Map.get(records, key, [])} end)
    end)
  end

  def dedupe_records(records) do
    Map.new(records, fn {key, values} ->
      {key, dedupe_provider_refs(values)}
    end)
  end

  def persist_records(records, opts) do
    actor = Keyword.fetch!(opts, :actor)
    records = resolve_existing_device_uids(records, actor)

    with {:ok, cluster_ids} <- upsert_group(VirtualizationCluster, records.clusters, actor),
         host_rows = link_refs(records.hosts, cluster_ids, %{}),
         {:ok, host_ids} <- upsert_group(VirtualizationHost, host_rows, actor),
         datastores = link_refs(records.datastores, cluster_ids, host_ids),
         disks = link_refs(records.host_disks, %{}, host_ids),
         guests = link_refs(records.guests, %{}, host_ids),
         {:ok, guest_ids} <- upsert_group(VirtualizationGuest, guests, actor),
         nics = link_network_interface_refs(records.network_interfaces, host_ids, guest_ids),
         storage_systems = link_refs(records.storage_systems, cluster_ids, host_ids),
         {:ok, _} <- upsert_group(VirtualizationDatastore, datastores, actor),
         {:ok, _} <- upsert_group(VirtualizationHostDisk, disks, actor),
         {:ok, _} <- upsert_group(VirtualizationNetworkInterface, nics, actor),
         {:ok, _} <- upsert_group(VirtualizationStorageSystem, storage_systems, actor) do
      :ok
    end
  end

  defp records_for_payload(payload, status, opts) do
    payload
    |> details()
    |> build_records(Keyword.get(opts, :observed_at) || observed_at(payload, status))
  end

  defp build_records(details, observed_at) when is_map(details) do
    provider = string_value(details, "provider")

    Enum.reduce(@record_keys, empty_records(), fn key, acc ->
      records =
        key
        |> records_for_key(details)
        |> Enum.map(&normalize_record(&1, key, provider, observed_at))
        |> Enum.filter(&valid_record?/1)

      Map.put(acc, key, records)
    end)
  end

  defp build_records(_details, _observed_at), do: empty_records()

  defp records_for_key(key, details) do
    @record_sources
    |> Map.fetch!(key)
    |> Enum.flat_map(&list_value(details, &1))
  end

  defp normalize_record(record, key, default_provider, observed_at) do
    allowed = Map.fetch!(@field_allowlist, key)

    record
    |> Enum.reduce(%{}, fn {raw_key, raw_value}, acc ->
      field = normalize_field(raw_key)

      if field in allowed do
        Map.put(acc, field, normalize_field_value(field, raw_value))
      else
        acc
      end
    end)
    |> maybe_put_default(:provider, default_provider)
    |> maybe_put_console_provider_ref(key)
    |> maybe_put_default(:metadata, %{})
    |> maybe_put_default(:observed_at, observed_at)
    |> sanitize_record_metadata()
  end

  defp maybe_put_console_provider_ref(%{provider_ref: provider_ref} = record, :console_targets)
       when provider_ref not in [nil, ""], do: record

  defp maybe_put_console_provider_ref(%{target_ref: target_ref} = record, :console_targets)
       when target_ref not in [nil, ""], do: Map.put(record, :provider_ref, target_ref)

  defp maybe_put_console_provider_ref(record, _key), do: record

  defp normalize_field(key) when is_atom(key), do: key

  defp normalize_field(key) when is_binary(key) do
    key
    |> String.replace("-", "_")
    |> then(&Map.get(@field_by_name, &1))
  end

  defp normalize_field(_key), do: nil

  defp normalize_field_value(:metadata, value), do: sanitize_metadata(value)
  defp normalize_field_value(:observed_at, value), do: parse_time(value) || value
  defp normalize_field_value(:ip_addresses, value), do: list_string(value)
  defp normalize_field_value(_field, value), do: value

  defp maybe_put_default(record, _key, value) when value in [nil, ""], do: record

  defp maybe_put_default(record, key, value) do
    case Map.get(record, key) do
      nil -> Map.put(record, key, value)
      "" -> Map.put(record, key, value)
      _ -> record
    end
  end

  defp sanitize_record_metadata(record) do
    Map.update(record, :metadata, %{}, &sanitize_metadata/1)
  end

  defp valid_record?(%{provider: provider, provider_ref: provider_ref}) do
    present?(provider) and present?(provider_ref)
  end

  defp valid_record?(_record), do: false

  defp details(%{"details" => raw}) when is_binary(raw) do
    case Jason.decode(raw) do
      {:ok, decoded} when is_map(decoded) -> decoded
      _ -> nil
    end
  end

  defp details(%{"details" => raw}) when is_map(raw), do: raw
  defp details(%{"schema" => @schema} = raw), do: raw
  defp details(_payload), do: nil

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

    network_identity = network_identity_by_guest(records.network_interfaces, actor)
    devices = lookup_devices(current_uids, names, actor)

    Map.merge(records, %{
      hosts: Enum.map(records.hosts, &resolve_record_device_uid(&1, devices)),
      guests:
        Enum.map(records.guests, fn record ->
          resolve_record_device_uid(record, devices, network_identity)
        end),
      host_disks: Enum.map(records.host_disks, &resolve_record_device_uid(&1, devices)),
      network_interfaces:
        Enum.map(records.network_interfaces, fn record ->
          resolve_record_device_uid(record, devices, network_identity)
        end)
    })
  end

  defp lookup_devices([], [], _actor), do: %{by_uid: %{}, by_name: %{}}

  defp lookup_devices(uids, names, actor) do
    uids = Enum.uniq(uids)
    names = Enum.uniq(names)
    filter = device_lookup_filter(uids, names)

    Device
    |> Ash.Query.for_read(:read, %{include_deleted: false})
    |> Ash.Query.filter_input(filter)
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
        Logger.warning("Hypervisor enrichment device lookup failed: #{inspect(reason)}")
        %{by_uid: %{}, by_name: %{}}
    end
  end

  defp device_lookup_filter(uids, names) do
    conditions =
      []
      |> maybe_add_filter_condition(uids, %{"uid" => %{"in" => uids}})
      |> maybe_add_filter_condition(names, %{"name" => %{"in" => names}})
      |> maybe_add_filter_condition(names, %{"hostname" => %{"in" => names}})

    %{"or" => conditions}
  end

  defp maybe_add_filter_condition(conditions, [], _condition), do: conditions
  defp maybe_add_filter_condition(conditions, _values, condition), do: [condition | conditions]

  defp network_identity_by_guest(network_interfaces, actor) do
    identities =
      network_interfaces
      |> Enum.filter(&present?(Map.get(&1, :guest_provider_ref)))
      |> Enum.flat_map(fn iface ->
        guest_ref = Map.fetch!(iface, :guest_provider_ref)

        macs =
          iface
          |> Map.get(:mac_address)
          |> List.wrap()
          |> Enum.map(&normalize_mac_identifier/1)
          |> Enum.filter(&present?/1)

        ips =
          iface
          |> Map.get(:ip_addresses, [])
          |> Enum.map(&normalize_ip_identifier/1)
          |> Enum.filter(&present?/1)

        partition =
          iface
          |> Map.get(:metadata, %{})
          |> string_value("partition")
          |> Kernel.||("default")

        Enum.map(macs, &%{guest_ref: guest_ref, type: :mac, value: &1, partition: partition}) ++
          Enum.map(ips, &%{guest_ref: guest_ref, type: :ip, value: &1, partition: partition})
      end)

    if identities == [] do
      %{}
    else
      identifiers =
        identities
        |> Enum.map(&Map.take(&1, [:type, :value, :partition]))
        |> Enum.uniq()

      identifier_to_device =
        DeviceIdentifier
        |> Ash.Query.for_read(:lookup_any, %{identifiers: identifiers})
        |> Ash.read(actor: actor)
        |> unwrap_page()
        |> case do
          {:ok, rows} ->
            Map.new(rows, fn row ->
              {{row.identifier_type, row.identifier_value, row.partition || "default"},
               row.device_id}
            end)

          {:error, reason} ->
            Logger.warning(
              "Hypervisor enrichment device identifier lookup failed: #{inspect(reason)}"
            )

            %{}
        end

      Enum.reduce(identities, %{}, fn identity, acc ->
        key = {identity.type, identity.value, identity.partition}

        case Map.get(identifier_to_device, key) do
          uid when is_binary(uid) and uid != "" -> Map.put_new(acc, identity.guest_ref, uid)
          _ -> acc
        end
      end)
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

  defp resolve_record_device_uid(record, devices, network_identity) do
    current_uid = Map.get(record, :device_uid)

    resolved =
      Map.get(devices.by_uid, current_uid) ||
        lookup_device_by_network_identity(record, network_identity) ||
        lookup_device_by_record_name(record, devices) ||
        existing_sr_uid(current_uid)

    Map.put(record, :device_uid, resolved)
  end

  defp lookup_device_by_network_identity(record, network_identity) do
    Enum.find_value(
      [Map.get(record, :guest_provider_ref), Map.get(record, :provider_ref)],
      &Map.get(network_identity, &1)
    )
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

  defp node_name_from_provider_ref(value) when is_binary(value) do
    case String.split(value, ":") do
      [_provider, "node", node | _] -> node
      [_provider, "host", host | _] -> host
      [_provider, kind, node | _] when kind in ["disk", "nic", "guest"] -> node
      _ -> nil
    end
  end

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
      :guest_id,
      :guest_provider_ref,
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
      :mac_address,
      :ip_addresses,
      :source,
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

  defp link_network_interface_refs(rows, host_ids, guest_ids) do
    Enum.map(rows, fn row ->
      row
      |> maybe_link_ref(:host_provider_ref, :host_id, host_ids)
      |> maybe_link_ref(:guest_provider_ref, :guest_id, guest_ids)
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

  defp list_value(map, key) when is_map(map), do: map |> field_value(key) |> list()
  defp list_value(_map, _key), do: []

  defp list(values) when is_list(values), do: Enum.filter(values, &is_map/1)
  defp list(_values), do: []

  defp string_value(map, key) when is_map(map) do
    case field_value(map, key) do
      value when is_binary(value) -> value |> String.trim() |> blank_to_nil()
      value when is_integer(value) -> Integer.to_string(value)
      value when is_float(value) -> Float.to_string(value)
      _ -> nil
    end
  end

  defp string_value(_map, _key), do: nil

  defp list_string(value) when is_list(value) do
    value
    |> Enum.map(&stringify_scalar/1)
    |> Enum.map(&String.trim/1)
    |> Enum.filter(&present?/1)
  end

  defp list_string(value) when is_binary(value) do
    value
    |> String.split([",", " "], trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.filter(&present?/1)
  end

  defp list_string(_value), do: []

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

  defp normalize_ip_identifier(value) when is_binary(value) do
    value
    |> strip_cidr()
    |> normalize_ip_cidr()
  end

  defp normalize_ip_identifier(_value), do: nil

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
