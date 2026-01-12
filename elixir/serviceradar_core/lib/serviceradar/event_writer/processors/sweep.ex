defmodule ServiceRadar.EventWriter.Processors.Sweep do
  @moduledoc """
  Processor for network sweep/discovery messages in OCSF Network Activity format.

  Parses sweep results from NATS JetStream and inserts them into
  the `ocsf_network_activity` hypertable using OCSF v1.3.0 Network Activity
  schema (class_uid: 4001) with activity_id: 99 (Scan).

  Also updates device inventory via SweepResultsIngestor:
  - Updates device availability status
  - Adds "sweep" to discovery_sources
  - Creates new device records for unknown hosts
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

  alias ServiceRadar.EventWriter.FieldParser
  alias ServiceRadar.EventWriter.OCSF
  alias ServiceRadar.EventWriter.TenantContext
  alias ServiceRadar.SweepJobs.SweepResultsIngestor

  require Logger

  @impl true
  def table_name, do: "ocsf_network_activity"

  @impl true
  def process_batch(messages) do
    schema = TenantContext.current_schema()
    tenant_id = TenantContext.current_tenant()

    if is_nil(schema) do
      Logger.error("Sweep batch missing tenant schema context")
      {:error, :missing_tenant_schema}
    else
      rows =
        messages
        |> Enum.map(&parse_message/1)
        |> Enum.reject(&is_nil/1)

      if Enum.empty?(rows) do
        {:ok, 0}
      else
        case ServiceRadar.Repo.insert_all(table_name(), rows,
               prefix: schema,
               on_conflict: :nothing,
               returning: false
             ) do
          {count, _} ->
            # Also update device inventory via SweepResultsIngestor
            process_inventory_updates(messages, tenant_id)
            {:ok, count}
        end
      end
    end
  rescue
    e ->
      Logger.error("Sweep OCSF batch insert failed: #{inspect(e)}")
      {:error, e}
  end

  # Process inventory updates for sweep results
  defp process_inventory_updates(messages, tenant_id) when is_binary(tenant_id) do
    # Parse messages and group by execution_id
    parsed_results =
      messages
      |> Enum.map(&parse_for_inventory/1)
      |> Enum.reject(&is_nil/1)

    # Group by execution_id (or nil for messages without execution context)
    results_by_execution = Enum.group_by(parsed_results, & &1["execution_id"])

    Enum.each(results_by_execution, fn {execution_id, results} ->
      if execution_id do
        # Extract additional context from first result
        first_result = List.first(results) || %{}
        sweep_group_id = first_result["sweep_group_id"] || first_result["sweepGroupId"]
        agent_id = first_result["agent_id"] || first_result["agentId"]
        config_version = first_result["config_hash"] || first_result["configHash"]

        # Full ingest with SweepHostResult records
        opts = [
          sweep_group_id: sweep_group_id,
          agent_id: agent_id,
          config_version: config_version
        ]

        case SweepResultsIngestor.ingest_results(results, execution_id, tenant_id, opts) do
          {:ok, _stats} ->
            :ok

          {:error, reason} ->
            Logger.warning("SweepResultsIngestor failed: #{inspect(reason)}")
        end
      else
        # Just update device availability (no execution tracking)
        update_device_availability_only(results, tenant_id)
      end
    end)
  rescue
    e ->
      Logger.warning("Inventory update failed (non-fatal): #{inspect(e)}")
  end

  defp process_inventory_updates(_messages, _tenant_id), do: :ok

  defp parse_for_inventory(%{data: data}) do
    case Jason.decode(data) do
      {:ok, json} -> json
      {:error, _} -> nil
    end
  end

  defp update_device_availability_only(results, tenant_id) do
    alias ServiceRadar.Cluster.TenantSchemas
    alias ServiceRadar.Identity.DeviceLookup
    alias ServiceRadar.Inventory.Device
    alias ServiceRadar.Repo

    import Ecto.Query

    tenant_schema = TenantSchemas.schema_for_tenant(tenant_id)

    # Extract IPs
    ips =
      results
      |> Enum.map(fn r -> r["host_ip"] || r["hostIp"] || r["ip"] end)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    if length(ips) > 0 do
      # Lookup existing devices
      device_map = DeviceLookup.batch_lookup_by_ip(ips, actor: system_actor(tenant_id))
      timestamp = DateTime.utc_now() |> DateTime.truncate(:second)

      # Update available devices
      available_ips =
        results
        |> Enum.filter(fn r -> r["icmp_available"] || r["icmpAvailable"] end)
        |> Enum.map(fn r -> r["host_ip"] || r["hostIp"] || r["ip"] end)
        |> Enum.reject(&is_nil/1)

      available_uids =
        available_ips
        |> Enum.map(&Map.get(device_map, &1))
        |> Enum.reject(&is_nil/1)
        |> Enum.map(& &1.canonical_device_id)

      if length(available_uids) > 0 do
        from(d in {tenant_schema <> ".ocsf_devices", Device},
          where: d.uid in ^available_uids
        )
        |> Repo.update_all(set: [is_available: true, last_seen_time: timestamp, modified_time: timestamp])
      end

      # Update unavailable devices
      unavailable_ips =
        results
        |> Enum.reject(fn r -> r["icmp_available"] || r["icmpAvailable"] end)
        |> Enum.map(fn r -> r["host_ip"] || r["hostIp"] || r["ip"] end)
        |> Enum.reject(&is_nil/1)

      unavailable_uids =
        unavailable_ips
        |> Enum.map(&Map.get(device_map, &1))
        |> Enum.reject(&is_nil/1)
        |> Enum.map(& &1.canonical_device_id)

      if length(unavailable_uids) > 0 do
        from(d in {tenant_schema <> ".ocsf_devices", Device},
          where: d.uid in ^unavailable_uids
        )
        |> Repo.update_all(set: [is_available: false, modified_time: timestamp])
      end
    end
  rescue
    e ->
      Logger.warning("Device availability update failed: #{inspect(e)}")
  end

  defp system_actor(tenant_id) do
    %{id: "system", role: :super_admin, tenant_id: tenant_id}
  end

  @impl true
  def parse_message(%{data: data, metadata: metadata} = message) do
    tenant_id = TenantContext.resolve_tenant_id(message)

    if is_nil(tenant_id) do
      Logger.error("Sweep message missing tenant_id", subject: metadata[:subject])
      nil
    else
      case Jason.decode(data) do
        {:ok, json} ->
          parse_sweep_result(json, metadata, tenant_id)

        {:error, _} ->
          Logger.debug("Failed to parse sweep message as JSON")
          nil
      end
    end
  end

  # Private functions

  defp parse_sweep_result(json, nats_metadata, tenant_id) do
    time = FieldParser.parse_timestamp(FieldParser.get_field(json, "last_sweep_time", "lastSweepTime"))
    activity_id = OCSF.activity_network_scan()

    # Determine severity based on scan results
    severity_id = determine_severity(json)

    # Build source endpoint (the scanned host)
    src_endpoint = OCSF.build_network_endpoint(
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
      status_id: if(json["icmp_available"] || json["icmpAvailable"], do: OCSF.status_success(), else: OCSF.status_failure()),
      status: if(json["icmp_available"] || json["icmpAvailable"], do: "Success", else: "Failure"),
      status_code: nil,
      status_detail: nil,

      # OCSF Metadata
      metadata: OCSF.build_metadata(
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
      protocol_name: if(json["icmp_available"] || json["icmpAvailable"], do: "ICMP", else: nil),
      protocol_num: if(json["icmp_available"] || json["icmpAvailable"], do: 1, else: nil),

      # Direction (not applicable for sweep)
      direction: nil,
      direction_id: nil,

      # Response time as duration
      duration: FieldParser.get_field(json, "icmp_response_time_ns", "icmpResponseTimeNs"),

      # Device (the gateway that performed the sweep)
      device: OCSF.build_device(
        name: FieldParser.get_field(json, "gateway_id", "gatewayId")
      ),

      # Actor (the agent)
      actor: OCSF.build_actor(
        app_name: "ServiceRadar Agent",
        app_ver: "1.0.0"
      ),

      # Scan-specific fields
      scan_type: "network_discovery",
      ports_scanned: ports_scanned,
      ports_open: ports_open,
      icmp_available: FieldParser.get_field(json, "icmp_available", "icmpAvailable"),
      response_time_ns: FieldParser.get_field(json, "icmp_response_time_ns", "icmpResponseTimeNs"),

      # Unmapped data
      unmapped: extract_unmapped(json),

      # Raw data
      raw_data: nil,

      # Multi-tenancy
      tenant_id: tenant_id,

      # Gateway/Agent tracking
      gateway_id: FieldParser.get_field(json, "gateway_id", "gatewayId"),
      agent_id: FieldParser.get_field(json, "agent_id", "agentId"),

      # Record timestamp
      created_at: DateTime.utc_now()
    }
  end

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
    scanned = FieldParser.encode_jsonb(FieldParser.get_field(json, "tcp_ports_scanned", "tcpPortsScanned"))
    open = FieldParser.encode_jsonb(FieldParser.get_field(json, "tcp_ports_open", "tcpPortsOpen"))

    scanned_list = case scanned do
      list when is_list(list) -> Enum.map(list, &to_integer/1) |> Enum.reject(&is_nil/1)
      _ -> []
    end

    open_list = case open do
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
      first_seen firstSeen metadata tenant_id
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
