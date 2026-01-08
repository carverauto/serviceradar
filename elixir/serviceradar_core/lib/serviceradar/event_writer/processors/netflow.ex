defmodule ServiceRadar.EventWriter.Processors.NetFlow do
  @moduledoc """
  Processor for NetFlow/IPFIX metrics messages in OCSF Network Activity format.

  Parses NetFlow data from NATS JetStream and inserts them into
  the `ocsf_network_activity` hypertable using OCSF v1.3.0 Network Activity
  schema (class_uid: 4001) with activity_id: 6 (Traffic).

  ## OCSF Classification

  - Category: Network Activity (category_uid: 4)
  - Class: Network Activity (class_uid: 4001)
  - Activity: 6 (Traffic - network traffic report)

  ## Message Format

  JSON NetFlow messages:

  ```json
  {
    "timestamp": "2024-01-01T00:00:00Z",
    "gateway_id": "gateway-1",
    "agent_id": "agent-1",
    "device_id": "router-1",
    "flow_direction": "ingress",
    "src_addr": "192.168.1.100",
    "dst_addr": "10.0.0.1",
    "src_port": 45678,
    "dst_port": 443,
    "protocol": 6,
    "packets": 100,
    "octets": 150000
  }
  ```
  """

  @behaviour ServiceRadar.EventWriter.Processor

  alias ServiceRadar.EventWriter.FieldParser
  alias ServiceRadar.EventWriter.OCSF
  alias ServiceRadar.EventWriter.TenantContext

  require Logger

  @impl true
  def table_name, do: "ocsf_network_activity"

  @impl true
  def process_batch(messages) do
    schema = TenantContext.current_schema()

    if is_nil(schema) do
      Logger.error("NetFlow batch missing tenant schema context")
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
            {:ok, count}
        end
      end
    end
  rescue
    e ->
      Logger.error("NetFlow OCSF batch insert failed: #{inspect(e)}")
      {:error, e}
  end

  @impl true
  def parse_message(%{data: data, metadata: metadata} = message) do
    tenant_id = TenantContext.resolve_tenant_id(message)

    if is_nil(tenant_id) do
      Logger.error("NetFlow message missing tenant_id", subject: metadata[:subject])
      nil
    else
      case Jason.decode(data) do
        {:ok, json} ->
          parse_netflow(json, metadata, tenant_id)

        {:error, _} ->
          Logger.debug("Failed to parse netflow message as JSON")
          nil
      end
    end
  end

  # Private functions

  defp parse_netflow(json, nats_metadata, tenant_id) do
    time = FieldParser.parse_timestamp(json["timestamp"])
    activity_id = OCSF.activity_network_traffic()

    # Get protocol info
    protocol_num = json["protocol"]
    protocol_name = OCSF.protocol_name(protocol_num)

    # Build source endpoint
    src_endpoint = OCSF.build_network_endpoint(
      ip: FieldParser.get_field(json, "src_addr", "srcAddr") || json["sourceAddress"],
      port: FieldParser.get_field(json, "src_port", "srcPort") || json["sourcePort"]
    )

    # Build destination endpoint
    dst_endpoint = OCSF.build_network_endpoint(
      ip: FieldParser.get_field(json, "dst_addr", "dstAddr") || json["destinationAddress"],
      port: FieldParser.get_field(json, "dst_port", "dstPort") || json["destinationPort"]
    )

    # Build traffic statistics
    traffic = build_traffic_stats(json)

    # Build observables
    observables = build_flow_observables(json)

    # Determine direction
    {direction, direction_id} = parse_direction(json)

    %{
      # Primary key components
      id: UUID.uuid4(),
      time: time,

      # OCSF Classification (required)
      class_uid: OCSF.class_network_activity(),
      category_uid: OCSF.category_network_activity(),
      type_uid: OCSF.type_uid(OCSF.class_network_activity(), activity_id),
      activity_id: activity_id,
      severity_id: OCSF.severity_informational(),

      # Content
      message: build_traffic_message(json, protocol_name),
      severity: OCSF.severity_name(OCSF.severity_informational()),
      activity_name: OCSF.network_activity_name(activity_id),

      # Action (allowed for observed traffic)
      action_id: OCSF.action_allowed(),
      action: "Allowed",

      # Status
      status_id: OCSF.status_success(),
      status: "Success",
      status_code: nil,
      status_detail: nil,

      # OCSF Metadata
      metadata: OCSF.build_metadata(
        product_name: "NetFlowCollector",
        correlation_uid: nats_metadata[:subject]
      ),

      # Observables
      observables: observables,

      # Endpoints
      src_endpoint: src_endpoint,
      dst_endpoint: dst_endpoint,

      # Connection info
      connection_info: %{
        sampler_address: FieldParser.get_field(json, "sampler_address", "samplerAddress"),
        input_snmp: FieldParser.get_field(json, "input_snmp", "inputSnmp"),
        output_snmp: FieldParser.get_field(json, "output_snmp", "outputSnmp")
      },

      # Traffic statistics
      traffic: traffic,

      # Protocol
      protocol_name: protocol_name,
      protocol_num: protocol_num,

      # Direction
      direction: direction,
      direction_id: direction_id,

      # Duration (not typically in NetFlow v5, may be in IPFIX)
      duration: nil,

      # Device (the flow exporter/router)
      device: OCSF.build_device(
        uid: FieldParser.get_field(json, "device_id", "deviceId"),
        name: FieldParser.get_field(json, "device_id", "deviceId")
      ),

      # Actor (the gateway/collector)
      actor: OCSF.build_actor(
        app_name: "ServiceRadar NetFlow Collector",
        app_ver: "1.0.0"
      ),

      # Scan-specific fields (not applicable for NetFlow)
      scan_type: nil,
      ports_scanned: [],
      ports_open: [],
      icmp_available: nil,
      response_time_ns: nil,

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

  defp build_traffic_stats(json) do
    octets = json["octets"] || json["bytes"]
    packets = json["packets"]

    OCSF.build_traffic(
      bytes: octets,
      packets: packets
    )
  end

  defp build_flow_observables(json) do
    src_ip = FieldParser.get_field(json, "src_addr", "srcAddr") || json["sourceAddress"]
    dst_ip = FieldParser.get_field(json, "dst_addr", "dstAddr") || json["destinationAddress"]
    src_port = FieldParser.get_field(json, "src_port", "srcPort") || json["sourcePort"]
    dst_port = FieldParser.get_field(json, "dst_port", "dstPort") || json["destinationPort"]

    []
    |> maybe_add(src_ip, &OCSF.ip_observable/1)
    |> maybe_add(dst_ip, &OCSF.ip_observable/1)
    |> maybe_add(src_port, &OCSF.port_observable/1)
    |> maybe_add(dst_port, &OCSF.port_observable/1)
  end

  defp parse_direction(json) do
    direction = FieldParser.get_field(json, "flow_direction", "flowDirection")

    case direction do
      "ingress" -> {"Inbound", 1}
      "inbound" -> {"Inbound", 1}
      "in" -> {"Inbound", 1}
      "egress" -> {"Outbound", 2}
      "outbound" -> {"Outbound", 2}
      "out" -> {"Outbound", 2}
      "lateral" -> {"Lateral", 3}
      _ -> {nil, 0}
    end
  end

  defp build_traffic_message(json, protocol_name) do
    src_ip = FieldParser.get_field(json, "src_addr", "srcAddr") || json["sourceAddress"]
    dst_ip = FieldParser.get_field(json, "dst_addr", "dstAddr") || json["destinationAddress"]
    src_port = FieldParser.get_field(json, "src_port", "srcPort") || json["sourcePort"]
    dst_port = FieldParser.get_field(json, "dst_port", "dstPort") || json["destinationPort"]
    octets = json["octets"] || json["bytes"] || 0
    packets = json["packets"] || 0

    src = if src_port, do: "#{src_ip}:#{src_port}", else: src_ip
    dst = if dst_port, do: "#{dst_ip}:#{dst_port}", else: dst_ip

    "#{protocol_name} traffic: #{src} -> #{dst} (#{packets} pkts, #{format_bytes(octets)})"
  end

  defp format_bytes(bytes) when is_integer(bytes) and bytes >= 1_000_000_000 do
    "#{Float.round(bytes / 1_000_000_000, 2)} GB"
  end
  defp format_bytes(bytes) when is_integer(bytes) and bytes >= 1_000_000 do
    "#{Float.round(bytes / 1_000_000, 2)} MB"
  end
  defp format_bytes(bytes) when is_integer(bytes) and bytes >= 1_000 do
    "#{Float.round(bytes / 1_000, 2)} KB"
  end
  defp format_bytes(bytes) when is_integer(bytes), do: "#{bytes} B"
  defp format_bytes(_), do: "0 B"

  defp extract_unmapped(json) do
    known_fields = ~w(
      timestamp gateway_id gatewayId agent_id agentId device_id deviceId
      flow_direction flowDirection src_addr srcAddr sourceAddress
      dst_addr dstAddr destinationAddress src_port srcPort sourcePort
      dst_port dstPort destinationPort protocol packets octets bytes
      sampler_address samplerAddress input_snmp inputSnmp output_snmp outputSnmp
      metadata tenant_id
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
