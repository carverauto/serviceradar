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
  alias ServiceRadar.Observability.FlowPubSub

  require Logger

  @impl true
  def table_name, do: "ocsf_network_activity"

  @impl true
  def process_batch(messages) do
    # DB connection's search_path determines the schema
    rows = build_rows(messages)

    if Enum.empty?(rows) do
      {:ok, 0}
    else
      insert_netflow_rows(rows)
    end
  rescue
    e ->
      Logger.error("NetFlow OCSF batch insert failed: #{inspect(e)}")
      {:error, e}
  end

  @impl true
  def parse_message(%{data: data, metadata: metadata}) do
    # DB connection's search_path determines the schema
    case Jason.decode(data) do
      {:ok, json} ->
        parse_netflow(json, metadata)

      {:error, _} ->
        Logger.debug("Failed to parse netflow message as JSON")
        nil
    end
  end

  # Private functions

  defp build_rows(messages) do
    messages
    |> Enum.map(&parse_message/1)
    |> Enum.reject(&is_nil/1)
  end

  defp insert_netflow_rows(rows) do
    # DB connection's search_path determines the schema
    case ServiceRadar.Repo.insert_all(
           table_name(),
           rows,
           on_conflict: :nothing,
           returning: false
         ) do
      {count, _} ->
        FlowPubSub.broadcast_ingest(%{count: count})
        {:ok, count}
    end
  end

  # DB connection's search_path determines the schema
  # Produces a flat row matching the ocsf_network_activity table columns.
  defp parse_netflow(json, nats_metadata) do
    time = FieldParser.parse_timestamp(json["timestamp"])
    activity_id = OCSF.activity_network_traffic()

    protocol_num = json["protocol"]
    protocol_name = OCSF.protocol_name(protocol_num)

    src_ip = FieldParser.get_field(json, "src_addr", "srcAddr") || json["sourceAddress"]
    src_port = FieldParser.get_field(json, "src_port", "srcPort") || json["sourcePort"]
    dst_ip = FieldParser.get_field(json, "dst_addr", "dstAddr") || json["destinationAddress"]
    dst_port = FieldParser.get_field(json, "dst_port", "dstPort") || json["destinationPort"]

    octets = json["octets"] || json["bytes"] || 0
    packets = json["packets"] || 0

    # Build full OCSF payload for the JSONB column
    ocsf_payload = %{
      "class_uid" => OCSF.class_network_activity(),
      "category_uid" => OCSF.category_network_activity(),
      "activity_id" => activity_id,
      "type_uid" => OCSF.type_uid(OCSF.class_network_activity(), activity_id),
      "severity_id" => OCSF.severity_informational(),
      "message" => build_traffic_message(json, protocol_name),
      "src_endpoint" => %{"ip" => src_ip, "port" => src_port},
      "dst_endpoint" => %{"ip" => dst_ip, "port" => dst_port},
      "traffic" => %{"bytes" => octets, "packets" => packets},
      "protocol_name" => protocol_name,
      "protocol_num" => protocol_num,
      "metadata" =>
        OCSF.build_metadata(
          product_name: "NetFlowCollector",
          correlation_uid: nats_metadata[:subject]
        ),
      "sampler_address" =>
        FieldParser.get_field(json, "sampler_address", "samplerAddress"),
      "unmapped" => extract_unmapped(json)
    }

    # Flat row matching ocsf_network_activity table columns
    %{
      time: time,
      class_uid: OCSF.class_network_activity(),
      category_uid: OCSF.category_network_activity(),
      activity_id: activity_id,
      type_uid: OCSF.type_uid(OCSF.class_network_activity(), activity_id),
      severity_id: OCSF.severity_informational(),
      src_endpoint_ip: src_ip,
      src_endpoint_port: safe_int(src_port),
      src_as_number: safe_int(json["src_as"]),
      dst_endpoint_ip: dst_ip,
      dst_endpoint_port: safe_int(dst_port),
      dst_as_number: safe_int(json["dst_as"]),
      protocol_num: protocol_num,
      protocol_name: protocol_name,
      tcp_flags: json["tcp_flags"],
      bytes_total: octets,
      packets_total: packets,
      bytes_in: nil,
      bytes_out: nil,
      sampler_address:
        FieldParser.get_field(json, "sampler_address", "samplerAddress"),
      ocsf_payload: ocsf_payload,
      partition: "default",
      created_at: DateTime.utc_now()
    }
  end

  defp safe_int(nil), do: nil
  defp safe_int(v) when is_integer(v), do: v
  defp safe_int(_), do: nil

  defp build_traffic_message(json, protocol_name) do
    src_ip = flow_value(json, "src_addr", "srcAddr", "sourceAddress")
    dst_ip = flow_value(json, "dst_addr", "dstAddr", "destinationAddress")
    src_port = flow_value(json, "src_port", "srcPort", "sourcePort")
    dst_port = flow_value(json, "dst_port", "dstPort", "destinationPort")
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
      metadata
    )

    json
    |> Map.drop(known_fields)
    |> case do
      map when map == %{} -> %{}
      map -> map
    end
  end

  defp flow_value(json, snake_key, camel_key, fallback_key, default \\ nil) do
    json[snake_key] || json[camel_key] || json[fallback_key] || default
  end
end
