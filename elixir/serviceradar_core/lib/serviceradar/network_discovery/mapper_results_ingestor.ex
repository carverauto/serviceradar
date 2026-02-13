defmodule ServiceRadar.NetworkDiscovery.MapperResultsIngestor do
  @moduledoc """
  Ingests mapper interface and topology results into CNPG and projects topology into AGE.
  """

  require Logger
  require Ash.Query

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
         resolved_records <- resolve_device_ids(records, actor),
         classified_records <- InterfaceClassifier.classify_interfaces(resolved_records, actor) do
      if classified_records == [] do
        Logger.debug("No interfaces to ingest after device ID resolution")

        record_job_runs(updates,
          status: :error,
          include_interface_counts: true,
          error: "no interfaces discovered"
        )

        :ok
      else
        case insert_bulk(classified_records, Interface, actor, "interfaces") do
          :ok ->
            TopologyGraph.upsert_interfaces(classified_records)
            record_job_runs(updates, status: :success, include_interface_counts: true)
            :ok

          {:error, reason} ->
            record_job_runs(updates,
              status: :error,
              include_interface_counts: true,
              error: reason
            )

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
      record_job_runs(updates, status: :success)

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
        record_job_runs(updates, status: :success)

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
  # For IPs with no existing device, creates one via DIRE.
  defp resolve_device_ids([], _actor), do: []

  defp resolve_device_ids(records, actor) do
    # Extract unique device IPs from records
    device_ips =
      records
      |> Enum.map(& &1.device_ip)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    # Look up device UIDs by IP address
    ip_to_uid = lookup_device_uids_by_ip(device_ips)

    # For IPs with no existing device, create devices via DIRE
    ip_to_uid = create_missing_devices(records, ip_to_uid, actor)

    # Update records with resolved device_ids, filtering out those we can't resolve
    records
    |> Enum.map(fn record ->
      case Map.get(ip_to_uid, record.device_ip) do
        nil ->
          Logger.debug("No device found for interface IP: #{record.device_ip}")
          nil

        device_uid ->
          %{record | device_id: device_uid}
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  # Creates devices via DIRE for IPs that have no existing device record.
  # This closes the device creation gap for SNMP-polled devices that don't run agents.
  defp create_missing_devices(records, ip_to_uid, actor) do
    records
    |> Enum.map(& &1.device_ip)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.reject(&Map.has_key?(ip_to_uid, &1))
    |> Enum.reduce(ip_to_uid, fn device_ip, acc ->
      case create_device_for_ip(device_ip, records, acc, actor) do
        {:ok, device_uid} ->
          Map.put(acc, device_ip, device_uid)

        {:error, reason} ->
          Logger.warning(
            "Failed to create device for mapper-discovered IP #{device_ip}: #{inspect(reason)}"
          )

          acc
      end
    end)
  end

  defp create_device_for_ip(device_ip, records, ip_to_uid, actor) do
    # Get partition from the first record matching this IP
    partition = partition_for_device_ip(device_ip, records)

    # Use IP-only identity for mapper-created placeholder devices.
    # Interface ordering can vary between mapper runs, so using a "first MAC"
    # here can generate unstable UIDs and cause cross-device merge churn.
    ids = %{
      agent_id: nil,
      armis_id: nil,
      integration_id: nil,
      netbox_id: nil,
      mac: nil,
      ip: device_ip,
      partition: partition
    }

    # Generate deterministic sr: UUID via DIRE
    device_uid = IdentityReconciler.generate_deterministic_device_id(ids)

    # If this IP appears as an interface address on another device, set management_device_id
    management_device_id = find_management_device_uid(device_ip, records, ip_to_uid)

    # Create the device record
    attrs =
      %{
        uid: device_uid,
        ip: device_ip,
        discovery_sources: ["mapper"],
        metadata: %{
          "identity_state" => "provisional",
          "identity_source" => "mapper_ip_seed"
        }
      }
      |> maybe_put(:management_device_id, management_device_id)

    case Device
         |> Ash.Changeset.for_create(:create, attrs)
         |> Ash.create(actor: actor) do
      {:ok, _device} ->
        Logger.info("Mapper created device #{device_uid} for IP #{device_ip}")
        invalidate_stale_aliases(device_ip, device_uid, partition, actor)

        if management_device_id,
          do: TopologyGraph.upsert_managed_by(device_uid, management_device_id)

        {:ok, device_uid}

      {:error, %Ash.Error.Invalid{errors: errors}} ->
        recover_existing_device_uid(device_ip, errors)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp partition_for_device_ip(device_ip, records) do
    records
    |> Enum.find(fn record -> record.device_ip == device_ip end)
    |> case do
      nil -> "default"
      record -> record.partition || "default"
    end
  end

  # Checks if device_ip appears in any interface's ip_addresses belonging to a
  # different device, and returns that parent device's UID if found.
  defp find_management_device_uid(device_ip, records, ip_to_uid) do
    records
    |> Enum.find(fn record ->
      record.device_ip != device_ip &&
        is_list(record.ip_addresses) &&
        Enum.any?(record.ip_addresses, &ip_matches?(&1, device_ip))
    end)
    |> case do
      nil -> nil
      record -> Map.get(ip_to_uid, record.device_ip)
    end
  end

  # Matches an interface IP (which may include a CIDR suffix like "203.0.113.5/24")
  # against a bare IP address.
  defp ip_matches?(interface_ip, device_ip) when is_binary(interface_ip) do
    interface_ip == device_ip || String.starts_with?(interface_ip, device_ip <> "/")
  end

  defp ip_matches?(_, _), do: false

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp recover_existing_device_uid(device_ip, errors) do
    # Device may have been created concurrently; recover by re-reading by IP.
    if Enum.any?(errors, &match?(%Ash.Error.Changes.InvalidChanges{}, &1)) do
      case lookup_device_uids_by_ip([device_ip]) do
        %{^device_ip => uid} -> {:ok, uid}
        _ -> {:error, errors}
      end
    else
      {:error, errors}
    end
  end

  # Invalidate IP aliases on other devices when a new device is created at that IP.
  # Transitions active aliases to :stale so they no longer resolve in DIRE lookups.
  defp invalidate_stale_aliases(ip, new_device_uid, partition, actor) do
    alias ServiceRadar.Identity.DeviceAliasState

    query =
      DeviceAliasState
      |> Ash.Query.filter(
        alias_type == :ip and alias_value == ^ip and
          device_id != ^new_device_uid and
          partition == ^partition and
          state in [:confirmed, :updated, :detected]
      )

    case Ash.read(query, actor: actor) do
      {:ok, aliases} when aliases != [] ->
        Logger.info(
          "Invalidating #{length(aliases)} stale IP alias(es) for #{ip} " <>
            "(new device: #{new_device_uid})"
        )

        Enum.each(aliases, fn alias_state ->
          alias_state
          |> Ash.Changeset.for_update(:mark_stale, %{})
          |> Ash.update(actor: actor)
        end)

      _ ->
        :ok
    end
  rescue
    e ->
      Logger.warning("Failed to invalidate stale aliases for #{ip}: #{inspect(e)}")
      :ok
  end

  defp lookup_device_uids_by_ip([]), do: %{}

  defp lookup_device_uids_by_ip(ips) do
    query =
      from(d in Device,
        where: d.ip in ^ips,
        select: {d.ip, d.uid}
      )

    Repo.all(query)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Map.new(fn {ip, uids} ->
      # Prefer sr: UIDs over sweep-/other legacy device IDs
      uid = Enum.find(uids, List.first(uids), &String.starts_with?(&1, "sr:"))
      {ip, uid}
    end)
  rescue
    e ->
      Logger.warning("Device UID lookup failed: #{inspect(e)}")
      %{}
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

  @doc false
  def normalize_interface(update) when is_map(update) do
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
      partition: get_string(update, ["partition", :partition]) || "default",
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
      duplex:
        get_string(update, ["duplex", :duplex]) || get_string(metadata, ["duplex", :duplex]),
      metadata: metadata,
      available_metrics: get_metrics_list(update, ["available_metrics", :available_metrics]),
      created_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
    }

    if record.device_id && record.interface_uid do
      record
    else
      nil
    end
  end

  def normalize_interface(_update), do: nil

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

  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  defp insert_bulk(records, resource, actor, label) do
    {prepared_records, opts} = prepare_bulk_records(records, resource, actor)

    prepared_records
    |> Ash.bulk_create(resource, :create, opts)
    |> handle_bulk_result(label)
  end

  defp prepare_bulk_records(records, Interface, actor) do
    filtered = Enum.reject(records, &missing_interface_identity?/1)
    log_filtered_interfaces(records, filtered)

    deduped =
      filtered
      |> Enum.uniq_by(&interface_identity_key/1)
      |> dedupe_by_interface()

    log_deduped_interfaces(filtered, deduped)

    {deduped,
     [
       actor: actor,
       return_errors?: true,
       stop_on_error?: false,
       upsert?: true,
       upsert_identity: :unique_interface,
       upsert_fields: []
     ]}
  end

  defp prepare_bulk_records(records, _resource, actor) do
    {records,
     [
       actor: actor,
       return_errors?: true,
       stop_on_error?: false
     ]}
  end

  defp handle_bulk_result(%Ash.BulkResult{status: :success}, _label), do: :ok

  defp handle_bulk_result(%Ash.BulkResult{status: :error, errors: errors}, label) do
    # Check if all errors are TimescaleDB chunk-prefixed constraint violations
    # These occur because TimescaleDB prefixes constraint names with chunk IDs
    # (e.g., "1_2_discovered_interfaces_pkey" instead of "discovered_interfaces_pkey")
    if timescaledb_pkey_violations?(errors) do
      Logger.debug(
        "Mapper #{label}: skipped #{length(List.wrap(errors))} duplicate(s) (TimescaleDB constraint)"
      )

      :ok
    else
      Logger.warning("Mapper #{label} ingestion failed: #{inspect(errors)}")
      {:error, errors}
    end
  end

  defp handle_bulk_result({:error, reason}, label) do
    Logger.warning("Mapper #{label} ingestion failed: #{inspect(reason)}")
    {:error, reason}
  end

  defp missing_interface_identity?(record) do
    key = interface_identity_key(record)
    elem(key, 0) == nil or elem(key, 1) == nil or elem(key, 2) == nil
  end

  defp log_filtered_interfaces(records, filtered) do
    if length(filtered) != length(records) do
      Logger.debug(
        "Mapper interfaces batch dropped #{length(records) - length(filtered)} record(s) missing identity fields"
      )
    end
  end

  defp log_deduped_interfaces(filtered, deduped) do
    if length(deduped) != length(filtered) do
      Logger.debug(
        "Mapper interfaces batch contained duplicates, deduped #{length(filtered) - length(deduped)} record(s)"
      )
    end
  end

  # Check if errors are all TimescaleDB chunk-prefixed primary key constraint violations.
  # TimescaleDB creates chunk-specific constraint names like "1_2_discovered_interfaces_pkey"
  # which Ash/Ecto can't match to the base constraint "discovered_interfaces_pkey".
  defp timescaledb_pkey_violations?(errors) when is_list(errors) do
    Enum.all?(errors, &timescaledb_pkey_violation?/1)
  end

  defp timescaledb_pkey_violations?(%Ash.Error.Unknown{errors: nested_errors}) do
    timescaledb_pkey_violations?(nested_errors)
  end

  defp timescaledb_pkey_violations?(_), do: false

  defp timescaledb_pkey_violation?(%Ash.Error.Unknown{errors: nested_errors}) do
    Enum.all?(nested_errors, &timescaledb_pkey_violation?/1)
  end

  defp timescaledb_pkey_violation?(%Ash.Error.Unknown.UnknownError{error: error_msg})
       when is_binary(error_msg) do
    # Match patterns like "1_2_discovered_interfaces_pkey" or "1_3_topology_links_pkey"
    String.contains?(error_msg, "unique_constraint") and
      Regex.match?(~r/\d+_\d+_\w+_pkey/, error_msg)
  end

  defp timescaledb_pkey_violation?(_), do: false

  defp interface_identity_key(record) when is_map(record) do
    {
      get_record_value(record, :timestamp, "timestamp"),
      get_record_value(record, :device_id, "device_id"),
      get_record_value(record, :interface_uid, "interface_uid")
    }
  end

  defp interface_identity_key(_record), do: {nil, nil, nil}

  defp get_record_value(record, atom_key, string_key) when is_map(record) do
    Map.get(record, atom_key) || Map.get(record, string_key)
  end

  defp dedupe_by_interface(records) do
    records
    |> Enum.group_by(fn record ->
      {
        get_record_value(record, :device_id, "device_id"),
        get_record_value(record, :interface_uid, "interface_uid")
      }
    end)
    |> Enum.map(fn {_key, grouped} -> newest_record(grouped) end)
  end

  defp newest_record([record]), do: record

  defp newest_record(records) do
    Enum.max_by(records, &record_timestamp/1, fn -> List.first(records) end)
  end

  defp record_timestamp(record) do
    case get_record_value(record, :timestamp, "timestamp") do
      %DateTime{} = timestamp -> timestamp
      _ -> DateTime.from_unix!(0)
    end
  end

  defp record_job_runs(updates, opts) do
    job_counts = extract_job_counts(updates)

    case map_size(job_counts) do
      0 ->
        :ok

      _ ->
        run_context = build_run_context(opts)

        Enum.each(job_counts, fn {job_id, count} ->
          record_job_run(
            job_id,
            run_context.now,
            run_context.status,
            interface_count(count, run_context.include_counts),
            run_context.error,
            run_context.actor
          )
        end)
    end
  rescue
    error ->
      Logger.warning("Mapper run status update failed: #{inspect(error)}")
      :ok
  end

  defp record_job_run(job_id, now, status, interface_count, error, actor) do
    case Ash.get(MapperJob, job_id, actor: actor) do
      {:ok, job} ->
        attrs = %{
          last_run_at: now,
          last_run_status: status
        }

        attrs =
          case interface_count do
            :skip -> attrs
            value -> Map.put(attrs, :last_run_interface_count, value)
          end

        attrs =
          if status == :error do
            Map.put(attrs, :last_run_error, format_run_error(error))
          else
            Map.put(attrs, :last_run_error, nil)
          end

        job
        |> Ash.Changeset.for_update(:record_run, attrs)
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

  defp format_run_error(nil), do: nil
  defp format_run_error(value) when is_binary(value), do: value
  defp format_run_error(value), do: inspect(value)

  defp build_run_context(opts) do
    %{
      now: DateTime.utc_now() |> DateTime.truncate(:microsecond),
      actor: SystemActor.system(:mapper_job_status),
      status: Keyword.get(opts, :status, :success),
      error: Keyword.get(opts, :error),
      include_counts: Keyword.get(opts, :include_interface_counts, false)
    }
  end

  defp interface_count(count, true), do: count
  defp interface_count(_count, false), do: :skip

  defp extract_job_counts(updates) do
    updates
    |> Enum.reduce(%{}, fn update, acc ->
      meta = get_map(update, ["metadata", :metadata])

      case get_string(meta, ["mapper_job_id", :mapper_job_id]) do
        nil -> acc
        job_id -> Map.update(acc, job_id, 1, &(&1 + 1))
      end
    end)
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

  # Get available_metrics list, ensuring it's nil if empty/invalid
  defp get_metrics_list(update, keys) do
    case get_value(update, keys) do
      [_ | _] = value ->
        # Normalize each metric to ensure consistent key format
        Enum.map(value, &normalize_metric/1)

      _ ->
        nil
    end
  end

  defp normalize_metric(metric) when is_map(metric) do
    %{
      "name" => get_string(metric, ["name", :name, "Name"]),
      "oid" => get_string(metric, ["oid", :oid, "OID"]),
      "data_type" => get_string(metric, ["data_type", :data_type, "DataType"]),
      "supports_64bit" =>
        get_boolean(metric, ["supports_64bit", :supports_64bit, "Supports64Bit"]),
      "oid_64bit" => get_string(metric, ["oid_64bit", :oid_64bit, "OID64Bit"]),
      "category" => get_string(metric, ["category", :category, "Category"]),
      "unit" => get_string(metric, ["unit", :unit, "Unit"])
    }
  end

  defp normalize_metric(_), do: nil

  defp get_boolean(update, keys) do
    case get_value(update, keys) do
      true -> true
      false -> false
      "true" -> true
      "false" -> false
      _ -> false
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
