defmodule ServiceRadar.NetworkDiscovery.MapperResultsIngestor do
  @moduledoc """
  Ingests mapper interface and topology results into CNPG and projects topology into AGE.
  """

  require Logger

  import Ecto.Query

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Inventory.{Device, IdentityReconciler}
  alias ServiceRadar.NetworkDiscovery.{MapperJob, TopologyGraph, TopologyLink}
  alias ServiceRadar.Repo

  @spec ingest_interfaces(binary() | nil, map()) :: :ok | {:error, term()}
  def ingest_interfaces(message, _status) do
    actor = SystemActor.system(:mapper_interface_ingestor)

    with {:ok, updates} <- decode_payload(message),
         records <- build_interface_records(updates),
         resolved_records <- resolve_device_ids(records) do
      record_job_runs(updates)

      if resolved_records == [] do
        Logger.debug("No interfaces to ingest after device ID resolution")
        :ok
      else
        case upsert_network_interfaces(resolved_records, actor) do
          :ok ->
            TopologyGraph.upsert_interfaces(resolved_records)
            register_interface_identifiers(resolved_records, actor)
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
      macs =
        iface_records
        |> Enum.map(&IdentityReconciler.normalize_mac(&1.if_phys_address))
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()

      Enum.each(macs, fn mac ->
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
      end)
    end)
  end

  defp upsert_network_interfaces([], _actor), do: :ok

  defp upsert_network_interfaces(records, actor) do
    records
    |> Enum.group_by(& &1.device_id)
    |> Enum.reduce([], fn {device_id, iface_records}, errors ->
      case upsert_device_network_interfaces(device_id, iface_records, actor) do
        :ok -> errors
        {:error, reason} -> [{device_id, reason} | errors]
      end
    end)
    |> case do
      [] -> :ok
      errors -> {:error, Enum.reverse(errors)}
    end
  end

  defp upsert_device_network_interfaces(device_id, iface_records, actor) do
    entries = build_network_interfaces(iface_records)

    if entries == [] do
      :ok
    else
      case Ash.get(Device, device_id, actor: actor) do
        {:ok, device} ->
          existing = ensure_list(device.network_interfaces)
          merged = merge_network_interfaces(existing, entries)

          if merged == existing do
            :ok
          else
            device
            |> Ash.Changeset.for_update(:update, %{network_interfaces: merged})
            |> Ash.update(actor: actor)
            |> case do
              {:ok, _device} ->
                :ok

              {:error, reason} ->
                Logger.warning(
                  "Failed to update network interfaces for device #{device_id}: #{inspect(reason)}"
                )

                {:error, reason}
            end
          end

        {:error, %Ash.Error.Query.NotFound{}} ->
          Logger.debug("No device found for interface update: #{device_id}")
          :ok

        {:error, reason} ->
          Logger.warning("Device lookup failed for interface update #{device_id}: #{inspect(reason)}")
          {:error, reason}
      end
    end
  end

  defp build_network_interfaces(records) do
    records
    |> Enum.reduce({MapSet.new(), []}, fn record, {seen, acc} ->
      entry = discovered_interface_to_ocsf(record)

      if map_size(entry) == 0 do
        {seen, acc}
      else
        key = interface_key(entry)

        if MapSet.member?(seen, key) do
          {seen, acc}
        else
          {MapSet.put(seen, key), [entry | acc]}
        end
      end
    end)
    |> then(fn {_seen, entries} -> Enum.reverse(entries) end)
  end

  defp discovered_interface_to_ocsf(record) do
    ip =
      case record.ip_addresses do
        [first | _rest] -> non_blank(first)
        _ -> nil
      end || non_blank(record.device_ip)

    name = non_blank(record.if_name) || non_blank(record.if_descr)
    mac = non_blank(record.if_phys_address)
    descr = non_blank(record.if_descr)
    alias_value = non_blank(record.if_alias)

    ip_addresses =
      record.ip_addresses
      |> Enum.map(&non_blank/1)
      |> Enum.reject(&is_nil/1)

    uid =
      case record.if_index do
        index when is_integer(index) -> Integer.to_string(index)
        _ -> nil
      end

    %{}
    |> put_if_present("ip", ip)
    |> put_if_list("ip_addresses", ip_addresses)
    |> put_if_present("name", name)
    |> put_if_present("descr", descr)
    |> put_if_present("alias", alias_value)
    |> put_if_present("mac", mac)
    |> put_if_present("uid", uid)
    |> put_if_present("speed", record.if_speed)
    |> put_if_present("admin_status", record.if_admin_status)
    |> put_if_present("oper_status", record.if_oper_status)
  end

  defp merge_network_interfaces(existing, incoming) do
    {seen, existing_unique} =
      Enum.reduce(existing, {MapSet.new(), []}, fn iface, {seen, acc} ->
        key = interface_key(iface)

        if MapSet.member?(seen, key) do
          {seen, acc}
        else
          {MapSet.put(seen, key), [iface | acc]}
        end
      end)

    existing_unique = Enum.reverse(existing_unique)

    {_, incoming_unique} =
      Enum.reduce(incoming, {seen, []}, fn iface, {seen, acc} ->
        key = interface_key(iface)

        if MapSet.member?(seen, key) do
          {seen, acc}
        else
          {MapSet.put(seen, key), [iface | acc]}
        end
      end)

    existing_unique ++ Enum.reverse(incoming_unique)
  end

  defp interface_key(iface) do
    %{
      name: normalize_key(iface_value(iface, :name)),
      mac: normalize_key(iface_value(iface, :mac)),
      ip: normalize_key(iface_value(iface, :ip)),
      uid: normalize_key(iface_value(iface, :uid))
    }
  end

  defp iface_value(iface, key) when is_atom(key) do
    Map.get(iface, key) || Map.get(iface, Atom.to_string(key))
  end

  defp normalize_key(nil), do: ""
  defp normalize_key(value) when is_binary(value), do: String.trim(value)
  defp normalize_key(value), do: to_string(value)

  defp ensure_list(value) when is_list(value), do: value
  defp ensure_list(_value), do: []

  defp non_blank(nil), do: nil

  defp non_blank(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: nil, else: trimmed
  end

  defp non_blank(value), do: value

  defp put_if_present(map, _key, nil), do: map
  defp put_if_present(map, _key, ""), do: map
  defp put_if_present(map, key, value), do: Map.put(map, key, value)

  defp put_if_list(map, _key, []), do: map
  defp put_if_list(map, key, value) when is_list(value), do: Map.put(map, key, value)
  defp put_if_list(map, _key, _value), do: map

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
    record = %{
      timestamp: parse_timestamp(get_value(update, ["timestamp", :timestamp])),
      device_id: get_string(update, ["device_id", :device_id]),
      agent_id: get_string(update, ["agent_id", :agent_id]),
      gateway_id: get_string(update, ["gateway_id", :gateway_id]),
      device_ip: get_string(update, ["device_ip", :device_ip]),
      if_index: get_integer(update, ["if_index", :if_index]),
      if_name: get_string(update, ["if_name", :if_name]),
      if_descr: get_string(update, ["if_descr", :if_descr]),
      if_alias: get_string(update, ["if_alias", :if_alias]),
      if_speed: get_integer(update, ["if_speed", :if_speed]),
      if_phys_address: get_string(update, ["if_phys_address", :if_phys_address]),
      ip_addresses: get_list(update, ["ip_addresses", :ip_addresses]),
      if_admin_status: get_integer(update, ["if_admin_status", :if_admin_status]),
      if_oper_status: get_integer(update, ["if_oper_status", :if_oper_status]),
      metadata: get_map(update, ["metadata", :metadata]),
      created_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
    }

    if record.device_id && record.if_index do
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
