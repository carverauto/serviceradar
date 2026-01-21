defmodule ServiceRadar.NetworkDiscovery.MapperResultsIngestor do
  @moduledoc """
  Ingests mapper interface and topology results into CNPG and projects topology into AGE.
  """

  require Logger

  import Ecto.Query

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Inventory.{Device, IdentityReconciler, Interface, InterfaceClassifier}
  alias ServiceRadar.NetworkDiscovery.{MapperJob, TopologyGraph, TopologyLink}
  alias ServiceRadar.Repo

  @spec ingest_interfaces(binary() | nil, map()) :: :ok | {:error, term()}
  def ingest_interfaces(message, _status) do
    actor = SystemActor.system(:mapper_interface_ingestor)

    with {:ok, updates} <- decode_payload(message),
         records <- build_interface_records(updates),
         resolved_records <- resolve_device_ids(records),
         classified_records <- InterfaceClassifier.classify_interfaces(resolved_records, actor) do
      record_job_runs(updates)

      if classified_records == [] do
        Logger.debug("No interfaces to ingest after device ID resolution")
        :ok
      else
        case insert_bulk(classified_records, Interface, actor, "interfaces") do
          :ok ->
            TopologyGraph.upsert_interfaces(classified_records)
            register_interface_identifiers(classified_records, actor)
            :ok

          {:error, reason} ->
            {:error, reason}
        end
      end
    else
      {:error, reason} ->
        Logger.warning("Mapper interface ingestion failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @spec ingest_topology(binary() | nil, map()) :: :ok | {:error, term()}
  def ingest_topology(message, _status) do
    actor = SystemActor.system(:mapper_topology_ingestor)

    with {:ok, updates} <- decode_payload(message),
         records <- build_topology_records(updates),
         resolved_records <- resolve_topology_device_ids(records) do
      record_job_runs(updates)

      if resolved_records == [] do
        Logger.debug("No topology links to ingest after device ID resolution")
        :ok
      else
        case insert_bulk(resolved_records, TopologyLink, actor, "topology") do
          :ok ->
            TopologyGraph.upsert_links(resolved_records)
            :ok

          {:error, reason} ->
            {:error, reason}
        end
      end
    else
      {:error, reason} ->
        Logger.warning("Mapper topology ingestion failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  def record_runs_from_payload(message) do
    case decode_payload(message) do
      {:ok, updates} ->
        record_job_runs(updates)

      {:error, reason} ->
        Logger.debug("Mapper job run decode failed: #{inspect(reason)}")
        :ok
    end
  end

  defp decode_payload(nil), do: {:ok, []}

  defp decode_payload(message) when is_binary(message) do
    case Jason.decode(message) do
      {:ok, updates} when is_list(updates) -> {:ok, updates}
      {:ok, _} -> {:error, :unexpected_payload}
      {:error, reason} -> {:error, reason}
    end
  end

  defp decode_payload(_message), do: {:error, :unsupported_payload}

  defp build_interface_records(updates) do
    Enum.reduce(updates, [], fn update, acc ->
      case normalize_interface(update) do
        nil -> acc
        record -> [record | acc]
      end
    end)
    |> Enum.reverse()
  end

  # Resolve device_ids from device_ip addresses by looking up existing devices.
  # The agent sends device_id as "partition:ip" but Device.uid is "sr:<uuid>".
  # We need to look up the actual device UID from the IP address.
  defp resolve_device_ids([]), do: []

  defp resolve_device_ids(records) do
    # Extract unique device IPs from records
    device_ips =
      records
      |> Enum.map(& &1.device_ip)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    # Look up device UIDs by IP address
    ip_to_uid = lookup_device_uids_by_ip(device_ips)

    # Update records with resolved device_ids, filtering out those we can't resolve
    records
    |> Enum.map(fn record ->
      case Map.get(ip_to_uid, record.device_ip) do
        nil ->
          # No device found for this IP - log and skip
          Logger.debug("No device found for interface IP: #{record.device_ip}")
          nil

        device_uid ->
          %{record | device_id: device_uid}
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp lookup_device_uids_by_ip([]), do: %{}

  defp lookup_device_uids_by_ip(ips) do
    query =
      from(d in Device,
        where: d.ip in ^ips,
        select: {d.ip, d.uid}
      )

    Repo.all(query)
    |> Map.new()
  rescue
    e ->
      Logger.warning("Device UID lookup failed: #{inspect(e)}")
      %{}
  end

  defp register_interface_identifiers([], _actor), do: :ok

  defp register_interface_identifiers(records, actor) do
    records
    |> Enum.group_by(& &1.device_id)
    |> Enum.each(fn {device_id, iface_records} ->
      iface_records
      |> interface_macs()
      |> Enum.each(&register_interface_mac(device_id, &1, actor))
    end)
  end

  defp interface_macs(iface_records) do
    iface_records
    |> Enum.map(&IdentityReconciler.normalize_mac(&1.if_phys_address))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp register_interface_mac(device_id, mac, actor) do
    ids = %{
      armis_id: nil,
      integration_id: nil,
      netbox_id: nil,
      mac: mac,
      ip: "",
      partition: "default"
    }

    case IdentityReconciler.register_identifiers(device_id, ids, actor: actor) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "Failed to register interface MAC identifier for device #{device_id}: #{inspect(reason)}"
        )
    end
  end

  # Resolve device IDs for topology records (local_device_id and neighbor_device_id)
  defp resolve_topology_device_ids([]), do: []

  defp resolve_topology_device_ids(records) do
    # Extract unique device IPs from records (both local and neighbor)
    device_ips =
      records
      |> Enum.flat_map(fn record ->
        [record.local_device_ip, record.neighbor_mgmt_addr]
      end)
      |> Enum.reject(&is_nil/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    # Look up device UIDs by IP address
    ip_to_uid = lookup_device_uids_by_ip(device_ips)

    # Update records with resolved device_ids
    # For topology, we keep records even if we can't resolve neighbor (it may be external)
    records
    |> Enum.map(fn record ->
      local_uid = Map.get(ip_to_uid, record.local_device_ip)
      neighbor_uid = Map.get(ip_to_uid, record.neighbor_mgmt_addr)

      if local_uid do
        record
        |> Map.put(:local_device_id, local_uid)
        |> maybe_put_neighbor_id(neighbor_uid)
      else
        # No local device found - log and skip
        Logger.debug("No device found for topology local IP: #{record.local_device_ip}")
        nil
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp maybe_put_neighbor_id(record, nil), do: record
  defp maybe_put_neighbor_id(record, uid), do: Map.put(record, :neighbor_device_id, uid)

  defp build_topology_records(updates) do
    Enum.reduce(updates, [], fn update, acc ->
      case normalize_topology(update) do
        nil -> acc
        record -> [record | acc]
      end
    end)
    |> Enum.reverse()
  end

  defp normalize_interface(update) when is_map(update) do
    metadata = get_map(update, ["metadata", :metadata])

    if_type =
      get_integer(update, ["if_type", :if_type]) ||
        get_integer(metadata, ["if_type", :if_type])

    if_name = get_string(update, ["if_name", :if_name])
    if_descr = get_string(update, ["if_descr", :if_descr])
    if_index = get_integer(update, ["if_index", :if_index])
    {if_type_name, interface_kind} = classify_if_type(if_type, if_name)
    interface_uid = build_interface_uid(if_index, if_name, if_descr)
    speed_bps = get_integer(update, ["speed_bps", :speed_bps])
    if_speed = get_integer(update, ["if_speed", :if_speed])

    record = %{
      timestamp: parse_timestamp(get_value(update, ["timestamp", :timestamp])),
      device_id: get_string(update, ["device_id", :device_id]),
      interface_uid: interface_uid,
      agent_id: get_string(update, ["agent_id", :agent_id]),
      gateway_id: get_string(update, ["gateway_id", :gateway_id]),
      device_ip: get_string(update, ["device_ip", :device_ip]),
      if_index: if_index,
      if_name: if_name,
      if_descr: if_descr,
      if_alias: get_string(update, ["if_alias", :if_alias]),
      if_speed: if_speed,
      speed_bps: speed_bps || if_speed,
      if_phys_address: get_string(update, ["if_phys_address", :if_phys_address]),
      ip_addresses: get_list(update, ["ip_addresses", :ip_addresses]),
      if_admin_status: get_integer(update, ["if_admin_status", :if_admin_status]),
      if_oper_status: get_integer(update, ["if_oper_status", :if_oper_status]),
      if_type: if_type,
      if_type_name: if_type_name,
      interface_kind: interface_kind,
      mtu: get_integer(update, ["mtu", :mtu]) || get_integer(metadata, ["mtu", :mtu]),
      duplex: get_string(update, ["duplex", :duplex]) || get_string(metadata, ["duplex", :duplex]),
      metadata: metadata,
      created_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
    }

    if record.device_id && record.interface_uid do
      record
    else
      nil
    end
  end

  defp normalize_interface(_update), do: nil

  defp normalize_topology(update) when is_map(update) do
    %{
      timestamp: parse_timestamp(get_value(update, ["timestamp", :timestamp])),
      agent_id: get_string(update, ["agent_id", :agent_id]),
      gateway_id: get_string(update, ["gateway_id", :gateway_id]),
      partition: get_string(update, ["partition", :partition]) || "default",
      protocol: get_string(update, ["protocol", :protocol]),
      local_device_ip: get_string(update, ["local_device_ip", :local_device_ip]),
      local_device_id: get_string(update, ["local_device_id", :local_device_id]),
      local_if_index: get_integer(update, ["local_if_index", :local_if_index]),
      local_if_name: get_string(update, ["local_if_name", :local_if_name]),
      neighbor_device_id: get_string(update, ["neighbor_device_id", :neighbor_device_id]),
      neighbor_chassis_id: get_string(update, ["neighbor_chassis_id", :neighbor_chassis_id]),
      neighbor_port_id: get_string(update, ["neighbor_port_id", :neighbor_port_id]),
      neighbor_port_descr: get_string(update, ["neighbor_port_descr", :neighbor_port_descr]),
      neighbor_system_name: get_string(update, ["neighbor_system_name", :neighbor_system_name]),
      neighbor_mgmt_addr: get_string(update, ["neighbor_mgmt_addr", :neighbor_mgmt_addr]),
      metadata: get_map(update, ["metadata", :metadata]),
      created_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
    }
  end

  defp normalize_topology(_update), do: nil

  defp build_interface_uid(nil, if_name, if_descr) do
    cond do
      is_binary(if_name) and String.trim(if_name) != "" -> "ifname:#{String.trim(if_name)}"
      is_binary(if_descr) and String.trim(if_descr) != "" -> "ifdescr:#{String.trim(if_descr)}"
      true -> nil
    end
  end

  defp build_interface_uid(if_index, _if_name, _if_descr) when is_integer(if_index) do
    "ifindex:#{if_index}"
  end

  defp classify_if_type(nil, if_name) do
    case classify_if_name(if_name) do
      nil -> {nil, nil}
      kind -> {nil, kind}
    end
  end

  defp classify_if_type(if_type, if_name) when is_integer(if_type) do
    case interface_type_map(if_type) do
      {name, kind} -> {name, kind}
      nil -> {nil, classify_if_name(if_name)}
    end
  end

  @interface_type_map %{
    1 => {"other", "unknown"},
    6 => {"ethernetCsmacd", "physical"},
    24 => {"softwareLoopback", "loopback"},
    53 => {"propVirtual", "virtual"},
    62 => {"fastEthernet", "physical"},
    69 => {"fastEthernetFx", "physical"},
    71 => {"ieee80211", "wireless"},
    117 => {"gigabitEthernet", "physical"},
    131 => {"tunnel", "tunnel"},
    135 => {"l2vlan", "virtual"},
    136 => {"l3ipvlan", "virtual"},
    161 => {"ieee8023adLag", "aggregate"},
    166 => {"mplsTunnel", "tunnel"},
    209 => {"bridge", "bridge"}
  }

  defp interface_type_map(if_type) do
    Map.get(@interface_type_map, if_type)
  end

  defp classify_if_name(nil), do: nil

  @interface_name_prefixes [
    {"lo", "loopback"},
    {"br", "bridge"},
    {"vlan", "virtual"},
    {"tun", "tunnel"},
    {"wg", "tunnel"},
    {"docker", "virtual"},
    {"veth", "virtual"}
  ]

  defp classify_if_name(if_name) when is_binary(if_name) do
    name = String.downcase(String.trim(if_name))
    interface_kind_for_name(name)
  end

  defp interface_kind_for_name(""), do: nil

  defp interface_kind_for_name(name) do
    Enum.find_value(@interface_name_prefixes, fn {prefix, kind} ->
      if String.starts_with?(name, prefix), do: kind
    end)
  end

  defp insert_bulk([], _resource, _actor, _label), do: :ok

  defp insert_bulk(records, resource, actor, label) do
    case Ash.bulk_create(records, resource, :create,
           actor: actor,
           return_errors?: true,
           stop_on_error?: false
         ) do
      %Ash.BulkResult{status: :success} ->
        :ok

      %Ash.BulkResult{status: :error, errors: errors} ->
        Logger.warning("Mapper #{label} ingestion failed: #{inspect(errors)}")
        {:error, errors}

      {:error, reason} ->
        Logger.warning("Mapper #{label} ingestion failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp record_job_runs(updates) do
    job_ids = extract_job_ids(updates)

    if job_ids == [] do
      :ok
    else
      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
      actor = SystemActor.system(:mapper_job_status)

      Enum.each(job_ids, &record_job_run(&1, now, actor))
    end
  rescue
    error ->
      Logger.warning("Mapper run status update failed: #{inspect(error)}")
      :ok
  end

  defp record_job_run(job_id, now, actor) do
    case Ash.get(MapperJob, job_id, actor: actor) do
      {:ok, job} ->
        job
        |> Ash.Changeset.for_update(:record_run, %{last_run_at: now})
        |> Ash.update(actor: actor)
        |> case do
          {:ok, _} ->
            :ok

          {:error, reason} ->
            Logger.warning("Failed to record mapper run: #{inspect(reason)}")
        end

      {:error, reason} ->
        Logger.debug("Mapper job not found for run update: #{inspect(reason)}")
    end
  end

  defp extract_job_ids(updates) do
    updates
    |> Enum.reduce(MapSet.new(), fn update, acc ->
      meta = get_map(update, ["metadata", :metadata])

      case get_string(meta, ["mapper_job_id", :mapper_job_id]) do
        nil -> acc
        job_id -> MapSet.put(acc, job_id)
      end
    end)
    |> MapSet.to_list()
  end

  defp get_value(update, keys) do
    Enum.find_value(keys, fn key -> Map.get(update, key) end)
  end

  defp get_string(update, keys) do
    case get_value(update, keys) do
      value when is_binary(value) -> value
      value when is_atom(value) -> Atom.to_string(value)
      _ -> nil
    end
  end

  defp get_integer(update, keys) do
    case get_value(update, keys) do
      value when is_integer(value) ->
        value

      value when is_float(value) ->
        trunc(value)

      value when is_binary(value) ->
        case Integer.parse(value) do
          {parsed, _} -> parsed
          :error -> nil
        end

      _ ->
        nil
    end
  end

  defp get_list(update, keys) do
    case get_value(update, keys) do
      value when is_list(value) -> value
      _ -> []
    end
  end

  defp get_map(update, keys) do
    case get_value(update, keys) do
      value when is_map(value) -> value
      _ -> %{}
    end
  end

  defp parse_timestamp(nil), do: DateTime.utc_now() |> DateTime.truncate(:microsecond)

  defp parse_timestamp(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _offset} -> DateTime.truncate(dt, :microsecond)
      _ -> DateTime.utc_now() |> DateTime.truncate(:microsecond)
    end
  end

  defp parse_timestamp(%DateTime{} = timestamp) do
    DateTime.truncate(timestamp, :microsecond)
  end
end
