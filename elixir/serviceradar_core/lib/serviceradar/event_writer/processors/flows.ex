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

  Raw flow messages:

  - canonical: protobuf `flowpb.FlowMessage`
  - legacy compatibility: JSON flow payloads
  """

  @behaviour ServiceRadar.EventWriter.Processor

  alias Flowpb.FlowMessage
  alias ServiceRadar.BGP.Ingestor
  alias ServiceRadar.EventWriter.FieldParser
  alias ServiceRadar.EventWriter.FlowEnrichment
  alias ServiceRadar.EventWriter.OCSF
  alias ServiceRadar.Observability.FlowPubSub

  require Logger

  @impl true
  def table_name, do: "ocsf_network_activity"

  @impl true
  def process_batch(messages) do
    processed_messages = build_processed_messages(messages)
    rows = Enum.map(processed_messages, & &1.row)

    if Enum.empty?(rows) do
      {:ok, 0}
    else
      with {:ok, count} <- insert_rows(rows) do
        persist_bgp_observations(processed_messages)
        {:ok, count}
      end
    end
  rescue
    e ->
      Logger.error("NetFlow OCSF batch insert failed: #{inspect(e)}")
      {:error, e}
  end

  @impl true
  def parse_message(%{data: data, metadata: metadata}) do
    case parse_processed_payload(data, metadata) do
      %{row: row} -> row
      nil -> nil
    end
  end

  def row_from_flow_message(%FlowMessage{} = flow, nats_metadata \\ %{}) do
    flow
    |> flow_message_to_json()
    |> parse_flow(nats_metadata)
  end

  def insert_rows(rows) when is_list(rows) do
    if Enum.empty?(rows) do
      {:ok, 0}
    else
      insert_netflow_rows(rows)
    end
  end

  # Private functions

  defp build_processed_messages(messages) do
    messages
    |> Enum.map(&parse_processed_message/1)
    |> Enum.reject(&is_nil/1)
  end

  defp parse_processed_message(%{data: data, metadata: metadata}) do
    parse_processed_payload(data, metadata)
  end

  defp parse_processed_payload("", _metadata), do: nil

  defp parse_processed_payload(data, metadata) when is_binary(data) do
    if json_payload?(data) do
      case Jason.decode(data) do
        {:ok, json} ->
          processed_from_json(json, metadata)

        {:error, _} ->
          Logger.debug("Failed to parse flow message as JSON")
          nil
      end
    else
      case FlowMessage.decode(data) do
        {:ok, flow} ->
          processed_from_flow_message(flow, metadata)

        flow when is_struct(flow, FlowMessage) ->
          processed_from_flow_message(flow, metadata)

        {:error, reason} ->
          Logger.debug("Failed to decode FlowMessage protobuf: #{inspect(reason)}")
          nil
      end
    end
  rescue
    e ->
      Logger.debug("Exception parsing flow message: #{inspect(e)}")
      nil
  end

  defp processed_from_json(json, metadata) do
    %{row: parse_flow(json, metadata), bgp_observation: nil}
  end

  defp processed_from_flow_message(%FlowMessage{} = flow, metadata) do
    %{
      row: row_from_flow_message(flow, metadata),
      bgp_observation: build_bgp_observation(flow, metadata)
    }
  end

  defp insert_netflow_rows(rows) do
    # DB connection's search_path determines the schema
    {count, _} =
      ServiceRadar.Repo.insert_all(
        table_name(),
        rows,
        on_conflict: :nothing,
        returning: false
      )

    FlowPubSub.broadcast_ingest(%{count: count})
    {:ok, count}
  end

  defp persist_bgp_observations(processed_messages) do
    observations =
      processed_messages
      |> Enum.map(& &1.bgp_observation)
      |> Enum.reject(&is_nil/1)

    if observations != [] do
      case Ingestor.batch_upsert_observations(observations) do
        {:ok, _ids} ->
          :ok

        {:error, reason} ->
          Logger.warning("Failed to upsert derived BGP observations: #{inspect(reason)}")
          :ok
      end
    else
      :ok
    end
  end

  # Produces a flat row matching the ocsf_network_activity table columns.
  defp parse_flow(json, nats_metadata) do
    time = FieldParser.parse_timestamp(json["timestamp"])
    start_time = optional_timestamp(json["start_time"] || json["startTime"])
    end_time = optional_timestamp(json["end_time"] || json["endTime"])
    activity_id = OCSF.activity_network_traffic()

    protocol_num = json["protocol"]
    protocol_name = OCSF.protocol_name(protocol_num)
    flow = parse_flow_fields(json)

    enrichment =
      FlowEnrichment.enrich(%{
        protocol_num: protocol_num,
        tcp_flags: json["tcp_flags"],
        dst_port: safe_int(flow.dst_port),
        bytes_in: flow.bytes_in,
        bytes_out: flow.bytes_out,
        src_ip: flow.src_ip,
        dst_ip: flow.dst_ip,
        src_mac: flow.src_mac,
        dst_mac: flow.dst_mac
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
      "src_endpoint" => %{"ip" => flow.src_ip, "port" => flow.src_port},
      "dst_endpoint" => %{"ip" => flow.dst_ip, "port" => flow.dst_port},
      "traffic" => %{"bytes" => flow.octets, "packets" => flow.packets},
      "connection_info" => %{
        "protocol_name" => protocol_name,
        "input_snmp" => FieldParser.get_field(json, "input_snmp", "inputSnmp"),
        "output_snmp" => FieldParser.get_field(json, "output_snmp", "outputSnmp")
      },
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
      start_time: start_time,
      end_time: end_time,
      src_endpoint_ip: flow.src_ip,
      src_endpoint_port: safe_int(flow.src_port),
      src_as_number: safe_int(json["src_as"]),
      dst_endpoint_ip: flow.dst_ip,
      dst_endpoint_port: safe_int(flow.dst_port),
      dst_as_number: safe_int(json["dst_as"]),
      protocol_num: protocol_num,
      protocol_name: protocol_name,
      protocol_source: enrichment.protocol_source,
      tcp_flags: json["tcp_flags"],
      tcp_flags_labels: enrichment.tcp_flags_labels,
      tcp_flags_source: enrichment.tcp_flags_source,
      dst_service_label: enrichment.dst_service_label,
      dst_service_source: enrichment.dst_service_source,
      bytes_total: flow.octets,
      packets_total: flow.packets,
      bytes_in: flow.bytes_in || 0,
      bytes_out: flow.bytes_out || 0,
      packets_in: flow.packets_in || 0,
      packets_out: flow.packets_out || 0,
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

  defp parse_flow_fields(json) do
    %{
      src_ip: endpoint_field(json, "src_addr", "srcAddr", "sourceAddress"),
      src_port: endpoint_field(json, "src_port", "srcPort", "sourcePort"),
      dst_ip: endpoint_field(json, "dst_addr", "dstAddr", "destinationAddress"),
      dst_port: endpoint_field(json, "dst_port", "dstPort", "destinationPort"),
      src_mac: flow_value(json, "src_mac", "srcMac", "sourceMac"),
      dst_mac: flow_value(json, "dst_mac", "dstMac", "destinationMac"),
      octets: first_present(json, ["octets", "bytes"], 0),
      packets: first_present(json, ["packets"], 0),
      bytes_in: safe_int(first_present(json, ["bytes_in", "bytesIn"])),
      bytes_out: safe_int(first_present(json, ["bytes_out", "bytesOut"])),
      packets_in: safe_int(first_present(json, ["packets_in", "packetsIn"])),
      packets_out: safe_int(first_present(json, ["packets_out", "packetsOut"]))
    }
  end

  defp safe_int(nil), do: nil
  defp safe_int(v) when is_integer(v), do: v
  defp safe_int(_), do: nil

  defp optional_timestamp(nil), do: nil
  defp optional_timestamp(ts), do: FieldParser.parse_timestamp(ts)

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
      start_time startTime end_time endTime
      flow_direction flowDirection src_addr srcAddr sourceAddress
      dst_addr dstAddr destinationAddress src_port srcPort sourcePort
      dst_port dstPort destinationPort protocol packets octets bytes
      bytes_in bytesIn bytes_out bytesOut packets_in packetsIn packets_out packetsOut
      tcp_flags tcpFlags protocol_name flow_source
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

  defp endpoint_field(json, snake_key, camel_key, fallback_key) do
    FieldParser.get_field(json, snake_key, camel_key) || json[fallback_key]
  end

  defp first_present(json, keys, default \\ nil) do
    Enum.find_value(keys, default, &Map.get(json, &1))
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

  defp json_payload?(data) when is_binary(data) do
    case String.trim_leading(data) do
      <<"{"::utf8, _::binary>> -> true
      <<"["::utf8, _::binary>> -> true
      _ -> false
    end
  end

  defp build_bgp_observation(%FlowMessage{} = flow, metadata) do
    as_path = normalize_u32_list(flow.as_path)

    if is_nil(as_path) do
      nil
    else
      %{
        timestamp: FieldParser.parse_timestamp(choose_timestamp(flow)),
        source_protocol: bgp_source_protocol(flow, metadata[:subject]),
        as_path: as_path,
        bgp_communities: normalize_u32_list(flow.bgp_communities) || [],
        src_ip: ip_bytes_to_string(flow.src_addr),
        dst_ip: ip_bytes_to_string(flow.dst_addr),
        bytes: flow.bytes || 0,
        packets: flow.packets || 0,
        metadata: %{
          sampler_address: ip_bytes_to_string(flow.sampler_address),
          subject: metadata[:subject],
          flow_source: flow_source_label(flow.type)
        }
      }
    end
  end

  defp normalize_u32_list([]), do: nil
  defp normalize_u32_list(nil), do: nil
  defp normalize_u32_list(values) when is_list(values), do: values

  defp bgp_source_protocol(flow, subject) do
    case normalize_flow_type(flow.type) do
      :SFLOW_5 -> "sflow"
      :NETFLOW_V5 -> "netflow"
      :NETFLOW_V9 -> "netflow"
      :IPFIX -> "netflow"
      _ -> bgp_source_protocol_from_subject(subject)
    end
  end

  defp bgp_source_protocol_from_subject(subject) when is_binary(subject) do
    cond do
      String.contains?(subject, "sflow") -> "sflow"
      String.contains?(subject, "netflow") -> "netflow"
      String.contains?(subject, "ipfix") -> "netflow"
      true -> "netflow"
    end
  end

  defp bgp_source_protocol_from_subject(_), do: "netflow"

  defp flow_message_to_json(flow) do
    %{
      "src_addr" => ip_bytes_to_string(flow.src_addr),
      "dst_addr" => ip_bytes_to_string(flow.dst_addr),
      "src_port" => zero_to_nil(flow.src_port),
      "dst_port" => zero_to_nil(flow.dst_port),
      "protocol" => zero_to_nil(flow.proto),
      "packets" => flow.packets,
      "bytes" => flow.bytes,
      "bytes_in" => optional_flow_field(flow, :bytes_in),
      "bytes_out" => optional_flow_field(flow, :bytes_out),
      "packets_in" => optional_flow_field(flow, :packets_in),
      "packets_out" => optional_flow_field(flow, :packets_out),
      "sampling_rate" => zero_to_nil(flow.sampling_rate),
      "sampler_address" => ip_bytes_to_string(flow.sampler_address),
      "input_snmp" => zero_to_nil(flow.in_if),
      "output_snmp" => zero_to_nil(flow.out_if),
      "tcp_flags" => zero_to_nil(flow.tcp_flags),
      "ip_tos" => zero_to_nil(flow.ip_tos),
      "src_as" => zero_to_nil(flow.src_as),
      "dst_as" => zero_to_nil(flow.dst_as),
      "protocol_name" => blank_to_nil(flow.protocol_name),
      "src_mac" => mac_to_string(flow.src_mac),
      "dst_mac" => mac_to_string(flow.dst_mac),
      "start_time" => zero_to_nil(flow.time_flow_start_ns),
      "end_time" => zero_to_nil(flow.time_flow_end_ns),
      "timestamp" => choose_timestamp(flow),
      "flow_source" => flow_source_label(flow.type)
    }
  end

  defp choose_timestamp(flow) do
    cond do
      flow.time_flow_end_ns > 0 -> flow.time_flow_end_ns
      flow.time_received_ns > 0 -> flow.time_received_ns
      flow.time_flow_start_ns > 0 -> flow.time_flow_start_ns
      true -> nil
    end
  end

  defp ip_bytes_to_string(nil), do: nil
  defp ip_bytes_to_string(""), do: nil

  defp ip_bytes_to_string(bytes) when is_binary(bytes) do
    case byte_size(bytes) do
      4 ->
        <<a, b, c, d>> = bytes
        {a, b, c, d} |> :inet.ntoa() |> to_string()

      16 ->
        <<a::16, b::16, c::16, d::16, e::16, f::16, g::16, h::16>> = bytes
        {a, b, c, d, e, f, g, h} |> :inet.ntoa() |> to_string()

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  defp mac_to_string(0), do: nil

  defp mac_to_string(mac) when is_integer(mac) do
    :io_lib.format(
      "~2.16.0B:~2.16.0B:~2.16.0B:~2.16.0B:~2.16.0B:~2.16.0B",
      [
        Bitwise.band(Bitwise.bsr(mac, 40), 0xFF),
        Bitwise.band(Bitwise.bsr(mac, 32), 0xFF),
        Bitwise.band(Bitwise.bsr(mac, 24), 0xFF),
        Bitwise.band(Bitwise.bsr(mac, 16), 0xFF),
        Bitwise.band(Bitwise.bsr(mac, 8), 0xFF),
        Bitwise.band(mac, 0xFF)
      ]
    )
    |> IO.iodata_to_binary()
  end

  defp mac_to_string(_), do: nil

  defp zero_to_nil(0), do: nil
  defp zero_to_nil(value), do: value

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  defp optional_flow_field(flow, key) do
    flow
    |> Map.get(key, 0)
    |> zero_to_nil()
  end

  defp flow_source_label(type) do
    case normalize_flow_type(type) do
      :SFLOW_5 -> "sFlow v5"
      :NETFLOW_V5 -> "NetFlow v5"
      :NETFLOW_V9 -> "NetFlow v9"
      :IPFIX -> "IPFIX"
      _ -> "Unknown"
    end
  rescue
    _ -> "Unknown"
  end

  defp normalize_flow_type(value) when is_atom(value), do: value
  defp normalize_flow_type(value), do: Flowpb.FlowMessage.FlowType.key(value)
end
