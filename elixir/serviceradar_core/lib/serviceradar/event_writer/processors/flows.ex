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
  - attributed: protobuf `flowpb.AttributedFlowMessage` on
    `flow.attributed.<partition>`
  - legacy compatibility: JSON flow payloads
  """

  @behaviour ServiceRadar.EventWriter.Processor

  alias Flowpb.AttributedFlowMessage
  alias Flowpb.FlowAttribution
  alias Flowpb.FlowMessage
  alias ServiceRadar.BGP.Ingestor
  alias ServiceRadar.EventWriter.BulkInsert
  alias ServiceRadar.EventWriter.FieldParser
  alias ServiceRadar.EventWriter.FlowEnrichment
  alias ServiceRadar.EventWriter.OCSF
  alias ServiceRadar.Observability.FlowPubSub
  alias ServiceRadar.Observability.NetflowInterfaceCacheRefreshWorker

  require Logger

  @attributed_flow_event_type "attributed_flow"
  @attributed_flow_subject_prefix "flow.attributed."

  # Attribution payload caps in BYTES (Mi-85, proto/flow/flow.proto:132-142).
  # Producers MUST cap redacted_cmdline at 256 bytes; comm/container_id are
  # byte-capped at their natural kernel/runtime limits (TASK_COMM_LEN and the
  # full Docker/containerd ID hex length, respectively).
  @comm_max_bytes 16
  @container_id_max_bytes 64
  @redacted_cmdline_max_bytes 256

  # Telemetry event names
  @telemetry_partition_mismatch [
    :serviceradar,
    :event_writer,
    :flows,
    :partition_mismatch
  ]
  @telemetry_attribution_truncated [
    :serviceradar,
    :flow_collector,
    :attribution,
    :truncated
  ]
  @telemetry_attributed_decode_failed [
    :serviceradar,
    :event_writer,
    :flows,
    :attributed_decode_failed
  ]

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
        record_netflow_interface_pairs(rows)
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

  def row_from_attributed_flow_message(%AttributedFlowMessage{} = message, nats_metadata \\ %{}) do
    message
    |> processed_from_attributed_flow_message(nats_metadata)
    |> case do
      %{row: row} -> row
      nil -> nil
    end
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
    FlowEnrichment.with_provider_cache(fn ->
      messages
      |> Enum.map(&parse_processed_message/1)
      |> Enum.reject(&is_nil/1)
    end)
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
      parse_protobuf_payload(data, metadata)
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

  defp processed_from_attributed_flow_message(
         %AttributedFlowMessage{
           event_type: @attributed_flow_event_type,
           flow: %FlowMessage{} = flow
         } = message,
         metadata
       ) do
    partition = resolve_partition(message, metadata)

    attribution = attribution_payload(message.attribution, metadata, partition)

    row =
      flow
      |> row_from_flow_message(metadata)
      |> Map.put(:partition, partition)
      |> Map.update!(:ocsf_payload, fn payload ->
        payload
        |> Map.put("event_type", @attributed_flow_event_type)
        |> put_if_present("agent_id", blank_to_nil(message.agent_id))
        |> put_if_present("partition", partition)
        |> put_if_present("attribution", attribution)
      end)

    %{
      row: row,
      bgp_observation: build_bgp_observation(flow, metadata)
    }
  end

  defp processed_from_attributed_flow_message(_message, _metadata), do: nil

  defp parse_protobuf_payload(data, metadata) do
    subject = metadata[:subject]

    if attributed_subject?(subject) do
      parse_attributed_protobuf_payload(data, metadata, subject)
    else
      parse_unattributed_protobuf_payload(data, metadata)
    end
  end

  defp parse_attributed_protobuf_payload(data, metadata, subject) do
    case decode_attributed_flow(data) do
      %AttributedFlowMessage{} = message ->
        case processed_from_attributed_flow_message(message, metadata) do
          %{row: _row} = processed ->
            processed

          nil ->
            emit_attributed_decode_failed(subject, :event_type_mismatch)
            nil
        end

      nil ->
        emit_attributed_decode_failed(subject, :decode_error)
        nil
    end
  end

  defp parse_unattributed_protobuf_payload(data, metadata) do
    with %AttributedFlowMessage{} = message <- decode_attributed_flow(data),
         %{row: _row} = processed <- processed_from_attributed_flow_message(message, metadata) do
      processed
    else
      _ -> parse_flow_message_payload(data, metadata)
    end
  end

  defp attributed_subject?(subject) when is_binary(subject) do
    String.starts_with?(subject, @attributed_flow_subject_prefix)
  end

  defp attributed_subject?(_), do: false

  defp emit_attributed_decode_failed(subject, reason) do
    :telemetry.execute(
      @telemetry_attributed_decode_failed,
      %{count: 1},
      %{subject: subject, reason: reason}
    )

    Logger.debug(
      "Attributed flow protobuf decode failed",
      subject: subject,
      reason: reason
    )
  end

  defp decode_attributed_flow(data) do
    case AttributedFlowMessage.decode(data) do
      {:ok, %AttributedFlowMessage{} = message} -> message
      %AttributedFlowMessage{} = message -> message
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp parse_flow_message_payload(data, metadata) do
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

  defp insert_netflow_rows(rows) do
    # DB connection's search_path determines the schema
    {count, _} =
      BulkInsert.insert_all(
        table_name(),
        rows,
        on_conflict: :nothing,
        returning: false
      )

    FlowPubSub.broadcast_ingest(%{count: count})
    {:ok, count}
  end

  defp record_netflow_interface_pairs(rows) do
    case NetflowInterfaceCacheRefreshWorker.record_observed_interface_pairs(rows) do
      {:ok, _count} ->
        :ok

      {:error, reason} ->
        Logger.warning("Failed to record observed NetFlow interface pairs: #{inspect(reason)}")
        :ok
    end
  end

  defp persist_bgp_observations(processed_messages) do
    observations =
      processed_messages
      |> Enum.map(& &1.bgp_observation)
      |> Enum.reject(&is_nil/1)

    if observations == [] do
      :ok
    else
      case Ingestor.batch_upsert_observations(observations) do
        {:ok, _ids} ->
          :ok

        {:error, reason} ->
          Logger.warning("Failed to upsert derived BGP observations: #{inspect(reason)}")
          :ok
      end
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
    sampling_rate = parse_sampling_rate(json)

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
      "traffic" => %{
        "bytes" => flow.octets,
        "packets" => flow.packets,
        "sampling_rate" => sampling_rate
      },
      "connection_info" => %{
        "protocol_name" => protocol_name,
        "input_snmp" => FieldParser.get_field(json, "input_snmp", "inputSnmp"),
        "output_snmp" => FieldParser.get_field(json, "output_snmp", "outputSnmp")
      },
      "protocol_name" => protocol_name,
      "protocol_num" => protocol_num,
      "flow_source" => flow_source,
      "enrichment" =>
        maybe_put_prefix_tags(
          %{
            "protocol_source" => enrichment.protocol_source,
            "tcp_flags_labels" => enrichment.tcp_flags_labels,
            "dst_service_label" => enrichment.dst_service_label,
            "direction_label" => enrichment.direction_label,
            "src_hosting_provider" => enrichment.src_hosting_provider,
            "dst_hosting_provider" => enrichment.dst_hosting_provider,
            "src_mac_vendor" => enrichment.src_mac_vendor,
            "dst_mac_vendor" => enrichment.dst_mac_vendor
          },
          enrichment
        ),
      "metadata" =>
        OCSF.build_metadata(
          product_name: "FlowCollector",
          correlation_uid: nats_metadata[:subject]
        ),
      "sampler_address" => FieldParser.get_field(json, "sampler_address", "samplerAddress"),
      "unmapped" => extract_unmapped(json)
    }

    # Flat row matching ocsf_network_activity table columns
    maybe_put_prefix_tag_columns(
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
        bytes_in: flow.bytes_in,
        bytes_out: flow.bytes_out,
        packets_in: flow.packets_in,
        packets_out: flow.packets_out,
        sampling_rate: sampling_rate,
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
      },
      enrichment
    )
  end

  defp maybe_put_prefix_tags(enrichment_map, enrichment) do
    enrichment_map
    |> maybe_put("src_prefix_tags", Map.get(enrichment, :src_prefix_tags))
    |> maybe_put("dst_prefix_tags", Map.get(enrichment, :dst_prefix_tags))
    |> maybe_put("src_prefix_tags_source", Map.get(enrichment, :src_prefix_tags_source))
    |> maybe_put("dst_prefix_tags_source", Map.get(enrichment, :dst_prefix_tags_source))
  end

  defp maybe_put_prefix_tag_columns(row, enrichment) do
    row
    |> maybe_put(:src_prefix_tags, Map.get(enrichment, :src_prefix_tags))
    |> maybe_put(:dst_prefix_tags, Map.get(enrichment, :dst_prefix_tags))
    |> maybe_put(:src_prefix_tags_source, Map.get(enrichment, :src_prefix_tags_source))
    |> maybe_put(:dst_prefix_tags_source, Map.get(enrichment, :dst_prefix_tags_source))
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

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
      sampling_rate samplingRate
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

  defp parse_sampling_rate(json) do
    json
    |> first_present(["sampling_rate", "samplingRate"], 1)
    |> to_positive_int(1)
  end

  defp to_positive_int(value, _default) when is_integer(value) and value > 0, do: value

  defp to_positive_int(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} when int > 0 -> int
      _ -> default
    end
  end

  defp to_positive_int(_value, default), do: default

  defp flow_source_from_subject(subject) when is_binary(subject) do
    cond do
      String.contains?(subject, "sflow") -> "sFlow"
      String.contains?(subject, "netflow") -> "NetFlow"
      String.contains?(subject, "ipfix") -> "IPFIX"
      true -> "Unknown"
    end
  end

  defp flow_source_from_subject(_), do: "Unknown"

  defp partition_from_attributed_subject(subject) when is_binary(subject) do
    if String.starts_with?(subject, @attributed_flow_subject_prefix) do
      subject
      |> String.replace_prefix(@attributed_flow_subject_prefix, "")
      |> String.split(".", parts: 2)
      |> List.first()
      |> blank_to_nil()
    end
  end

  defp partition_from_attributed_subject(_), do: nil

  defp attribution_payload(%FlowAttribution{} = attribution, metadata, partition) do
    subject = metadata[:subject]

    comm =
      attribution.comm
      |> blank_to_nil()
      |> cap_bytes("comm", @comm_max_bytes, subject, partition)

    redacted_cmdline =
      attribution.redacted_cmdline
      |> blank_to_nil()
      |> cap_bytes(
        "redacted_cmdline",
        @redacted_cmdline_max_bytes,
        subject,
        partition
      )

    container_id =
      attribution.container_id
      |> blank_to_nil()
      |> cap_bytes("container_id", @container_id_max_bytes, subject, partition)

    %{}
    |> put_if_present("pid", zero_to_nil(attribution.pid))
    |> put_if_present("comm", comm)
    |> put_if_present("redacted_cmdline", redacted_cmdline)
    |> put_if_present("uid", zero_to_nil(attribution.uid))
    |> put_if_present("container_id", container_id)
    |> case do
      map when map == %{} -> nil
      map -> map
    end
  end

  defp attribution_payload(_, _, _), do: nil

  # UTF-8-safe byte capper. The proto contract is expressed in bytes (see
  # proto/flow/flow.proto:132-142), so we measure with byte_size/1 and slice
  # via binary_part/3, then walk backwards at most 3 bytes to land on a valid
  # UTF-8 codepoint boundary (UTF-8 codepoints are 1-4 bytes).
  defp cap_bytes(nil, _field, _max, _subject, _partition), do: nil

  defp cap_bytes(value, field, max, subject, partition) when is_binary(value) do
    original_bytes = byte_size(value)

    if original_bytes > max do
      truncated = trim_to_utf8_boundary(binary_part(value, 0, max))

      :telemetry.execute(
        @telemetry_attribution_truncated,
        %{
          count: 1,
          original_bytes: original_bytes,
          truncated_bytes: byte_size(truncated)
        },
        %{field: field, subject: subject, partition: partition}
      )

      truncated
    else
      value
    end
  end

  defp cap_bytes(value, _field, _max, _subject, _partition), do: value

  defp trim_to_utf8_boundary(<<>>), do: <<>>

  defp trim_to_utf8_boundary(bin) when is_binary(bin) do
    if String.valid?(bin) do
      bin
    else
      trim_to_utf8_boundary(binary_part(bin, 0, byte_size(bin) - 1))
    end
  end

  defp resolve_partition(%AttributedFlowMessage{} = message, metadata) do
    subject = metadata[:subject]
    subject_partition = partition_from_attributed_subject(subject)
    body_partition = blank_to_nil(message.partition)

    cond do
      not is_nil(subject_partition) and not is_nil(body_partition) and
          subject_partition != body_partition ->
        emit_partition_mismatch(subject, body_partition, subject_partition)
        subject_partition

      not is_nil(subject_partition) ->
        subject_partition

      not is_nil(body_partition) ->
        body_partition

      true ->
        "default"
    end
  end

  defp emit_partition_mismatch(subject, body_partition, subject_partition) do
    :telemetry.execute(
      @telemetry_partition_mismatch,
      %{count: 1},
      %{
        subject: subject,
        body_partition: body_partition,
        subject_partition: subject_partition
      }
    )

    Logger.warning(
      "Attributed flow partition mismatch; trusting subject",
      subject: subject,
      body_partition: body_partition,
      subject_partition: subject_partition
    )
  end

  defp put_if_present(map, _key, nil), do: map
  defp put_if_present(map, key, value), do: Map.put(map, key, value)

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
    "~2.16.0B:~2.16.0B:~2.16.0B:~2.16.0B:~2.16.0B:~2.16.0B"
    |> :io_lib.format([
      Bitwise.band(Bitwise.bsr(mac, 40), 0xFF),
      Bitwise.band(Bitwise.bsr(mac, 32), 0xFF),
      Bitwise.band(Bitwise.bsr(mac, 24), 0xFF),
      Bitwise.band(Bitwise.bsr(mac, 16), 0xFF),
      Bitwise.band(Bitwise.bsr(mac, 8), 0xFF),
      Bitwise.band(mac, 0xFF)
    ])
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
