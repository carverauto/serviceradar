defmodule ServiceRadar.EventWriter.Processors.Flows do
  @moduledoc """
  Processor for flow telemetry (sFlow, NetFlow, IPFIX) in OCSF Network Activity format.

  Parses flow data from NATS JetStream and inserts them into
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
  alias ServiceRadar.EventWriter.FlowEnrichment
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
    case Jason.decode(data) do
      {:ok, json} ->
        parse_flow(json, metadata)

      {:error, _} ->
        Logger.debug("Failed to parse flow message as JSON")
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

  # Produces a flat row matching the ocsf_network_activity table columns.
  defp parse_flow(json, nats_metadata) do
    time = FieldParser.parse_timestamp(json["timestamp"])
    activity_id = OCSF.activity_network_traffic()

    protocol_num = json["protocol"]
    protocol_name = OCSF.protocol_name(protocol_num)

    src_ip = FieldParser.get_field(json, "src_addr", "srcAddr") || json["sourceAddress"]
    src_port = FieldParser.get_field(json, "src_port", "srcPort") || json["sourcePort"]
    dst_ip = FieldParser.get_field(json, "dst_addr", "dstAddr") || json["destinationAddress"]
    dst_port = FieldParser.get_field(json, "dst_port", "dstPort") || json["destinationPort"]
    src_mac = flow_value(json, "src_mac", "srcMac", "sourceMac")
    dst_mac = flow_value(json, "dst_mac", "dstMac", "destinationMac")

    octets = json["octets"] || json["bytes"] || 0
    packets = json["packets"] || 0
    bytes_in = safe_int(json["bytes_in"] || json["bytesIn"])
    bytes_out = safe_int(json["bytes_out"] || json["bytesOut"])

    enrichment =
      FlowEnrichment.enrich(%{
        protocol_num: protocol_num,
        tcp_flags: json["tcp_flags"],
        dst_port: safe_int(dst_port),
        bytes_in: bytes_in,
        bytes_out: bytes_out,
        src_ip: src_ip,
        dst_ip: dst_ip,
        src_mac: src_mac,
        dst_mac: dst_mac
      })

    # Prefer version-specific label from collector JSON, fall back to NATS subject
    flow_source = json["flow_source"] || flow_source_from_subject(nats_metadata[:subject])

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
      "flow_source" => flow_source,
      "enrichment" => %{
        "protocol_source" => enrichment.protocol_source,
        "tcp_flags_labels" => enrichment.tcp_flags_labels,
        "dst_service_label" => enrichment.dst_service_label,
        "direction_label" => enrichment.direction_label,
        "src_hosting_provider" => enrichment.src_hosting_provider,
        "dst_hosting_provider" => enrichment.dst_hosting_provider,
        "src_mac_vendor" => enrichment.src_mac_vendor,
        "dst_mac_vendor" => enrichment.dst_mac_vendor
      },
      "metadata" =>
        OCSF.build_metadata(
          product_name: "FlowCollector",
          correlation_uid: nats_metadata[:subject]
        ),
      "sampler_address" => FieldParser.get_field(json, "sampler_address", "samplerAddress"),
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
      protocol_source: enrichment.protocol_source,
      tcp_flags: json["tcp_flags"],
      tcp_flags_labels: enrichment.tcp_flags_labels,
      tcp_flags_source: enrichment.tcp_flags_source,
      dst_service_label: enrichment.dst_service_label,
      dst_service_source: enrichment.dst_service_source,
      bytes_total: octets,
      packets_total: packets,
      bytes_in: bytes_in || 0,
      bytes_out: bytes_out || 0,
      direction_label: enrichment.direction_label,
      direction_source: enrichment.direction_source,
      src_hosting_provider: enrichment.src_hosting_provider,
      src_hosting_provider_source: enrichment.src_hosting_provider_source,
      dst_hosting_provider: enrichment.dst_hosting_provider,
      dst_hosting_provider_source: enrichment.dst_hosting_provider_source,
      src_mac: enrichment.src_mac,
      dst_mac: enrichment.dst_mac,
      src_mac_vendor: enrichment.src_mac_vendor,
      src_mac_vendor_source: enrichment.src_mac_vendor_source,
      dst_mac_vendor: enrichment.dst_mac_vendor,
      dst_mac_vendor_source: enrichment.dst_mac_vendor_source,
      sampler_address: FieldParser.get_field(json, "sampler_address", "samplerAddress"),
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
      bytes_in bytesIn bytes_out bytesOut tcp_flags tcpFlags
      src_mac srcMac sourceMac dst_mac dstMac destinationMac
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

  defp flow_source_from_subject(subject) when is_binary(subject) do
    cond do
      String.contains?(subject, "sflow") -> "sFlow"
      String.contains?(subject, "netflow") -> "NetFlow"
      String.contains?(subject, "ipfix") -> "IPFIX"
      true -> "Unknown"
    end
  end

  defp flow_source_from_subject(_), do: "Unknown"
end
