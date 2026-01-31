defmodule ServiceRadar.EventWriter.Processors.Sweep do
  @moduledoc """
  Processor for network sweep/discovery messages in OCSF Network Activity format.

  Parses sweep results from NATS JetStream and inserts them into
  the `ocsf_network_activity` hypertable using OCSF v1.3.0 Network Activity
  schema (class_uid: 4001) with activity_id: 99 (Scan).

  Also updates device inventory via SweepResultsIngestor:
  - Updates device availability status
  - Adds "sweep" to discovery_sources
  - Ignores unknown hosts (only updates existing devices/aliases)
  - Stores SweepHostResult records (when execution_id is provided)

  ## OCSF Classification

  - Category: Network Activity (category_uid: 4)
  - Class: Network Activity (class_uid: 4001)
  - Activity: 99 (Scan/Discovery - custom activity for network discovery)

  ## Message Format

  JSON sweep result messages:

  ```json
  {
    "host_ip": "192.168.1.100",
    "gateway_id": "gateway-1",
    "agent_id": "agent-1",
    "partition": "default",
    "network_cidr": "192.168.1.0/24",
    "hostname": "server1",
    "mac": "00:11:22:33:44:55",
    "icmp_available": true,
    "icmp_response_time_ns": 1500000,
    "last_sweep_time": "2024-01-01T00:00:00Z",
    "execution_id": "uuid-for-sweep-execution-tracking",
    "sweep_group_id": "uuid-for-sweep-group",
    "config_hash": "hash-for-change-detection"
  }
  ```
  """

  @behaviour ServiceRadar.EventWriter.Processor

  alias ServiceRadar.Ash.Page
  alias ServiceRadar.EventWriter.FieldParser
  alias ServiceRadar.EventWriter.OCSF
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Repo
  alias ServiceRadar.SweepJobs.SweepResultsIngestor

  import Ecto.Query

  require Logger
  require Ash.Query

  @impl true
  def table_name, do: "ocsf_network_activity"

  @impl true
  def process_batch(messages) do
    # DB connection's search_path determines the schema
    rows = build_rows(messages)

    if Enum.empty?(rows) do
      {:ok, 0}
    else
      insert_sweep_rows(rows, messages)
    end
  rescue
    e ->
      Logger.error("Sweep OCSF batch insert failed: #{inspect(e)}")
      {:error, e}
  end

  defp build_rows(messages) do
    messages
    |> Enum.map(&parse_message/1)
    |> Enum.reject(&is_nil/1)
  end

  defp insert_sweep_rows(rows, messages) do
    # DB connection's search_path determines the schema
    case ServiceRadar.Repo.insert_all(
           table_name(),
           rows,
           on_conflict: :nothing,
           returning: false
         ) do
      {count, _} ->
        # Also update device inventory via SweepResultsIngestor
        process_inventory_updates(messages)
        {:ok, count}
    end
  end

  # Process inventory updates for sweep results
  # DB connection's search_path determines the schema
  defp process_inventory_updates(messages) do
    # Parse messages and group by execution_id
    parsed_results =
      messages
      |> Enum.map(&parse_for_inventory/1)
      |> Enum.reject(&is_nil/1)

    # Group by execution_id (or nil for messages without execution context)
    results_by_execution = Enum.group_by(parsed_results, & &1["execution_id"])

    Enum.each(results_by_execution, &process_execution_results/1)
  rescue
    e ->
      Logger.warning("Inventory update failed (non-fatal): #{inspect(e)}")
  end

  defp process_execution_results({nil, results}) do
    # Just update device availability (no execution tracking)
    update_device_availability_only(results)
  end

  defp process_execution_results({execution_id, results}) do
    # Extract additional context from first result
    first_result = List.first(results) || %{}
    sweep_group_id = first_result["sweep_group_id"] || first_result["sweepGroupId"]
    agent_id = first_result["agent_id"] || first_result["agentId"]
    config_version = first_result["config_hash"] || first_result["configHash"]

    # Full ingest with SweepHostResult records
    # DB connection's search_path determines the schema
    opts = [
      sweep_group_id: sweep_group_id,
      agent_id: agent_id,
      config_version: config_version
    ]

    case SweepResultsIngestor.ingest_results(results, execution_id, opts) do
      {:ok, _stats} ->
        :ok

      {:error, reason} ->
        Logger.warning("SweepResultsIngestor failed: #{inspect(reason)}")
    end
  end

  defp parse_for_inventory(%{data: data}) do
    case Jason.decode(data) do
      {:ok, json} -> json
      {:error, _} -> nil
    end
  end

  defp update_device_availability_only(results) do
    alias ServiceRadar.Actors.SystemActor
    alias ServiceRadar.Identity.DeviceLookup

    # DB connection's search_path determines the schema

    # Extract IPs
    ips =
      results
      |> Enum.map(fn r -> r["host_ip"] || r["hostIp"] || r["ip"] end)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    if Enum.empty?(ips) do
      :ok
    else
      # Lookup existing devices
      actor = SystemActor.system(:sweep_processor)
      device_map = DeviceLookup.batch_lookup_by_ip(ips, actor: actor, include_deleted: true)
      timestamp = DateTime.utc_now() |> DateTime.truncate(:second)

      update_availability(results, device_map, timestamp, actor)
    end
  rescue
    e ->
      Logger.warning("Device availability update failed: #{inspect(e)}")
  end

  defp update_availability(results, device_map, timestamp, actor) do
    restore_deleted_devices(device_uids_from_results(results, device_map), actor)
    update_available_devices(results, device_map, timestamp)
    update_unavailable_devices(results, device_map, timestamp)
  end

  defp device_uids_from_results(results, device_map) do
    results
    |> Enum.map(fn r -> r["host_ip"] || r["hostIp"] || r["ip"] end)
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&Map.get(device_map, &1))
    |> Enum.reject(&is_nil/1)
    |> Enum.map(& &1.canonical_device_id)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp restore_deleted_devices([], _actor), do: :ok

  defp restore_deleted_devices(device_uids, actor) do
    case load_deleted_devices(device_uids, actor) do
      {:ok, devices} ->
        devices
        |> eligible_restore_uids()
        |> restore_eligible_devices(actor)

      {:error, reason} ->
        Logger.warning("SweepProcessor: Restore lookup failed", error: inspect(reason))
        :ok
    end
  end

  defp load_deleted_devices(device_uids, actor) do
    Device
    |> Ash.Query.for_read(:read, %{include_deleted: true})
    |> Ash.Query.filter(uid in ^device_uids and not is_nil(deleted_at))
    |> Ash.read(actor: actor)
    |> Page.unwrap()
  end

  defp eligible_restore_uids(devices) do
    devices
    |> Enum.filter(&restore_eligible?/1)
    |> Enum.map(& &1.uid)
  end

  defp restore_eligible_devices([], _actor), do: :ok

  defp restore_eligible_devices(eligible_uids, actor) do
    restore_query =
      Device
      |> Ash.Query.for_read(:read, %{include_deleted: true})
      |> Ash.Query.filter(uid in ^eligible_uids)

    case Ash.bulk_update(restore_query, :restore, %{},
           actor: actor,
           return_records?: false,
           return_errors?: true
         ) do
      %Ash.BulkResult{status: :success} ->
        :ok

      %Ash.BulkResult{status: :partial_success, errors: errors} ->
        Logger.warning("SweepProcessor: Partial restore failures", errors: inspect(errors))

      %Ash.BulkResult{status: :error, errors: errors} ->
        Logger.warning("SweepProcessor: Restore failed", errors: inspect(errors))

      other ->
        Logger.warning("SweepProcessor: Restore unexpected result", result: inspect(other))
    end
  end

  defp restore_eligible?(device) do
    sources =
      device.discovery_sources
      |> List.wrap()
      |> Enum.reject(&is_nil/1)
      |> Enum.map(&to_string/1)

    Enum.any?(sources, fn source -> String.downcase(source) != "sweep" and source != "" end)
  end

  defp update_available_devices(results, device_map, timestamp) do
    # DB connection's search_path determines the schema
    available_uids =
      results
      |> Enum.filter(fn r -> r["icmp_available"] || r["icmpAvailable"] end)
      |> Enum.map(fn r -> r["host_ip"] || r["hostIp"] || r["ip"] end)
      |> Enum.reject(&is_nil/1)
      |> Enum.map(&Map.get(device_map, &1))
      |> Enum.reject(&is_nil/1)
      |> Enum.map(& &1.canonical_device_id)

    unless Enum.empty?(available_uids) do
      from(d in {"ocsf_devices", Device},
        where: d.uid in ^available_uids
      )
      |> Repo.update_all(
        set: [is_available: true, last_seen_time: timestamp, modified_time: timestamp]
      )
    end
  end

  defp update_unavailable_devices(results, device_map, timestamp) do
    # DB connection's search_path determines the schema
    unavailable_uids =
      results
      |> Enum.reject(fn r -> r["icmp_available"] || r["icmpAvailable"] end)
      |> Enum.map(fn r -> r["host_ip"] || r["hostIp"] || r["ip"] end)
      |> Enum.reject(&is_nil/1)
      |> Enum.map(&Map.get(device_map, &1))
      |> Enum.reject(&is_nil/1)
      |> Enum.map(& &1.canonical_device_id)

    unless Enum.empty?(unavailable_uids) do
      from(d in {"ocsf_devices", Device},
        where: d.uid in ^unavailable_uids
      )
      |> Repo.update_all(set: [is_available: false, modified_time: timestamp])
    end
  end

  @impl true
  def parse_message(%{data: data, metadata: metadata}) do
    # DB connection's search_path determines the schema
    case Jason.decode(data) do
      {:ok, json} ->
        parse_sweep_result(json, metadata)

      {:error, _} ->
        Logger.debug("Failed to parse sweep message as JSON")
        nil
    end
  end

  # Private functions
  # DB connection's search_path determines the schema
  defp parse_sweep_result(json, nats_metadata) do
    time =
      FieldParser.parse_timestamp(FieldParser.get_field(json, "last_sweep_time", "lastSweepTime"))

    activity_id = OCSF.activity_network_scan()
    icmp_available = FieldParser.get_field(json, "icmp_available", "icmpAvailable") || false
    response_time_ns = FieldParser.get_field(json, "icmp_response_time_ns", "icmpResponseTimeNs")
    {status_id, status} = status_from_icmp(icmp_available)
    {protocol_name, protocol_num} = protocol_from_icmp(icmp_available)

    # Determine severity based on scan results
    severity_id = determine_severity(json)

    # Build source endpoint (the scanned host)
    src_endpoint =
      OCSF.build_network_endpoint(
        ip: FieldParser.get_field(json, "host_ip", "hostIp") || json["ip"],
        hostname: json["hostname"],
        mac: json["mac"]
      )

    # Build observables from scan results
    observables = build_scan_observables(json)

    # Parse port scan results
    {ports_scanned, ports_open} = parse_port_results(json)

    %{
      # Primary key components
      id: UUID.uuid4(),
      time: time,

      # OCSF Classification (required)
      class_uid: OCSF.class_network_activity(),
      category_uid: OCSF.category_network_activity(),
      type_uid: OCSF.type_uid(OCSF.class_network_activity(), activity_id),
      activity_id: activity_id,
      severity_id: severity_id,

      # Content
      message: build_scan_message(json),
      severity: OCSF.severity_name(severity_id),
      activity_name: OCSF.network_activity_name(activity_id),

      # Status based on ICMP availability
      status_id: status_id,
      status: status,
      status_code: nil,
      status_detail: nil,

      # OCSF Metadata
      metadata:
        OCSF.build_metadata(
          product_name: "NetworkSweeper",
          correlation_uid: nats_metadata[:subject]
        ),

      # Observables
      observables: observables,

      # Endpoints
      src_endpoint: src_endpoint,
      dst_endpoint: %{},

      # Connection info (network CIDR for sweep scope)
      connection_info: %{
        network_cidr: FieldParser.get_field(json, "network_cidr", "networkCidr")
      },

      # Traffic (not applicable for sweep)
      traffic: %{},

      # Protocol (ICMP for ping sweep)
      protocol_name: protocol_name,
      protocol_num: protocol_num,

      # Direction (not applicable for sweep)
      direction: nil,
      direction_id: nil,

      # Response time as duration
      duration: FieldParser.get_field(json, "icmp_response_time_ns", "icmpResponseTimeNs"),

      # Device (the gateway that performed the sweep)
      device: OCSF.build_device(name: FieldParser.get_field(json, "gateway_id", "gatewayId")),

      # Actor (the agent)
      actor:
        OCSF.build_actor(
          app_name: "ServiceRadar Agent",
          app_ver: "1.0.0"
        ),

      # Scan-specific fields
      scan_type: "network_discovery",
      ports_scanned: ports_scanned,
      ports_open: ports_open,
      icmp_available: icmp_available,
      response_time_ns: response_time_ns,

      # Unmapped data
      unmapped: extract_unmapped(json),

      # Raw data
      raw_data: nil,

      # Gateway/Agent tracking
      gateway_id: FieldParser.get_field(json, "gateway_id", "gatewayId"),
      agent_id: FieldParser.get_field(json, "agent_id", "agentId"),

      # Record timestamp
      created_at: DateTime.utc_now()
    }
  end

  defp status_from_icmp(true), do: {OCSF.status_success(), "Success"}
  defp status_from_icmp(_), do: {OCSF.status_failure(), "Failure"}

  defp protocol_from_icmp(true), do: {"ICMP", 1}
  defp protocol_from_icmp(_), do: {nil, nil}

  defp determine_severity(json) do
    icmp = json["icmp_available"] || json["icmpAvailable"]
    open_ports = json["tcp_ports_open"] || json["tcpPortsOpen"] || []

    cond do
      # Host not responding - informational
      icmp == false and Enum.empty?(open_ports) -> OCSF.severity_informational()
      # Host responding with open ports - could be worth noting
      icmp == true and length(open_ports) > 5 -> OCSF.severity_low()
      # Normal discovery result
      true -> OCSF.severity_informational()
    end
  end

  defp build_scan_message(json) do
    ip = FieldParser.get_field(json, "host_ip", "hostIp") || json["ip"]
    hostname = json["hostname"]
    icmp = json["icmp_available"] || json["icmpAvailable"]

    status = if icmp, do: "reachable", else: "unreachable"
    host_info = if hostname, do: "#{hostname} (#{ip})", else: ip

    "Network scan: #{host_info} is #{status}"
  end

  defp build_scan_observables(json) do
    ip = FieldParser.get_field(json, "host_ip", "hostIp") || json["ip"]
    hostname = json["hostname"]
    mac = json["mac"]

    []
    |> maybe_add(ip, &OCSF.ip_observable/1)
    |> maybe_add(hostname, &OCSF.hostname_observable/1)
    |> maybe_add(mac, &OCSF.mac_observable/1)
  end

  defp parse_port_results(json) do
    scanned =
      FieldParser.encode_jsonb(
        FieldParser.get_field(json, "tcp_ports_scanned", "tcpPortsScanned")
      )

    open = FieldParser.encode_jsonb(FieldParser.get_field(json, "tcp_ports_open", "tcpPortsOpen"))

    scanned_list =
      case scanned do
        list when is_list(list) -> Enum.map(list, &to_integer/1) |> Enum.reject(&is_nil/1)
        _ -> []
      end

    open_list =
      case open do
        list when is_list(list) -> Enum.map(list, &to_integer/1) |> Enum.reject(&is_nil/1)
        _ -> []
      end

    {scanned_list, open_list}
  end

  defp to_integer(val) when is_integer(val), do: val

  defp to_integer(val) when is_binary(val) do
    case Integer.parse(val) do
      {int, _} -> int
      :error -> nil
    end
  end

  defp to_integer(_), do: nil

  defp extract_unmapped(json) do
    known_fields = ~w(
      host_ip hostIp ip gateway_id gatewayId agent_id agentId partition
      network_cidr networkCidr hostname mac icmp_available icmpAvailable
      icmp_response_time_ns icmpResponseTimeNs icmp_packet_loss icmpPacketLoss
      tcp_ports_scanned tcpPortsScanned tcp_ports_open tcpPortsOpen
      port_scan_results portScanResults last_sweep_time lastSweepTime
      first_seen firstSeen metadata
    )

    json
    |> Map.drop(known_fields)
    |> case do
      map when map == %{} -> %{}
      map -> map
    end
  end

  defp maybe_add(list, nil, _builder), do: list
  defp maybe_add(list, "", _builder), do: list
  defp maybe_add(list, value, builder), do: [builder.(value) | list]
end
