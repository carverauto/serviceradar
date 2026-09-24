defmodule ServiceRadar.Analytics.StarRocks.Rows do
  @moduledoc """
  Maps EventWriter-decoded rows onto StarRocks Stream Load JSON documents.
  """

  alias ServiceRadar.Analytics.StarRocks.Identity

  @type dataset :: Identity.dataset() | :mtr_traces | :mtr_hops

  # priv/starrocks/0019: every column of platform.mtr_traces / platform.mtr_hops
  # under the same name. Scalars are carried as built by
  # MtrMetricsIngestor.rows/2; nil stays NULL, and `false` and `0` stay what
  # they are.
  @mtr_trace_text ~w(agent_id gateway_id check_id check_name device_id target target_ip
                     protocol partition error)a

  @mtr_trace_values ~w(target_reached total_hops probed_hops last_responding_hop tcp_port
                       ip_version packet_size tcp_handshake_ttl tcp_handshake_attempts
                       tcp_syn_sent tcp_synack_received tcp_rst_received tcp_syn_unanswered
                       tcp_syn_drop_pct tcp_syn_retransmits tcp_answered_after_retx
                       tcp_ack_mismatch tcp_synack_duplicates tcp_handshake_rtt_min_us
                       tcp_handshake_rtt_avg_us tcp_handshake_rtt_max_us
                       tcp_server_response_us)a

  @mtr_hop_text ~w(target_ip device_id addr hostname asn_org)a

  @mtr_hop_values ~w(hop_number asn sent received loss_pct last_us avg_us min_us max_us
                     stddev_us jitter_us jitter_worst_us jitter_interarrival_us
                     unreachable_code reply_time_exceeded reply_unreachable reply_synack
                     reply_rst)a

  @spec encode(dataset(), [map()]) :: [map()]
  def encode(dataset, rows) when is_list(rows) do
    Enum.map(rows, &encode_row(dataset, &1))
  end

  defp encode_row(:flow_attribution, row) do
    %{
      "id" => Identity.record_id(:flow_attribution, row),
      "time" => datetime(field(row, :time)),
      "event_type" => "attributed_flow",
      "attribution_version" => field(row, :attribution_version),
      "pid" => field(row, :pid),
      "comm" => stringify(field(row, :comm)),
      "cmdline" => stringify(field(row, :cmdline)),
      "workload_identity" => json_text(field(row, :workload_identity))
    }
  end

  defp encode_row(:flows, row) do
    %{
      "id" => Identity.record_id(:flows, row),
      "device_uid" => stringify(field(row, :device_uid) || field(row, :device_id) || "unknown"),
      "event_type" => stringify(field(row, :event_type) || payload_text(row, "event_type")),
      "time" => datetime(field(row, :time)),
      "src_endpoint_ip" => stringify(field(row, :src_endpoint_ip)),
      "dst_endpoint_ip" => stringify(field(row, :dst_endpoint_ip)),
      "src_endpoint_port" => field(row, :src_endpoint_port),
      "dst_endpoint_port" => field(row, :dst_endpoint_port),
      "protocol_num" => field(row, :protocol_num),
      "protocol_name" => stringify(field(row, :protocol_name)),
      "direction_label" => stringify(field(row, :direction_label)),
      "dst_service_label" => stringify(field(row, :dst_service_label)),
      "bytes_total" =>
        field(row, :bytes_total) || sum_pair(field(row, :bytes_in), field(row, :bytes_out)),
      "packets_total" =>
        field(row, :packets_total) || sum_pair(field(row, :packets_in), field(row, :packets_out)),
      "start_time" => datetime(field(row, :start_time)),
      "end_time" => datetime(field(row, :end_time)),
      "src_as_number" => field(row, :src_as_number),
      "dst_as_number" => field(row, :dst_as_number),
      "tcp_flags" => field(row, :tcp_flags),
      "partition" => stringify(field(row, :partition)),
      "input_snmp" => connection_info_int(row, "input_snmp", :input_snmp),
      "output_snmp" => connection_info_int(row, "output_snmp", :output_snmp),
      "src_mac" => stringify(field(row, :src_mac)),
      "dst_mac" => stringify(field(row, :dst_mac)),
      "src_mac_vendor" => stringify(field(row, :src_mac_vendor)),
      "dst_mac_vendor" => stringify(field(row, :dst_mac_vendor)),
      "src_hosting_provider" => stringify(field(row, :src_hosting_provider)),
      "dst_hosting_provider" => stringify(field(row, :dst_hosting_provider)),
      "protocol_source" => stringify(field(row, :protocol_source)),
      "direction_source" => stringify(field(row, :direction_source)),
      "dst_service_source" => stringify(field(row, :dst_service_source)),
      "src_prefix_tags" => json_text(field(row, :src_prefix_tags)),
      "dst_prefix_tags" => json_text(field(row, :dst_prefix_tags)),
      "bytes_in" => field(row, :bytes_in),
      "bytes_out" => field(row, :bytes_out),
      "packets_in" => field(row, :packets_in),
      "packets_out" => field(row, :packets_out),
      "sampling_rate" => field(row, :sampling_rate) || 1,
      "attribution_version" => field(row, :attribution_version) || 0,
      "sampler_address" => stringify(field(row, :sampler_address))
    }
  end

  defp encode_row(:metrics, row) do
    %{
      "timestamp" => datetime(field(row, :timestamp)),
      "gateway_id" => stringify(field(row, :gateway_id)),
      "series_key" => stringify(field(row, :series_key)),
      "agent_id" => stringify(field(row, :agent_id)),
      "metric_name" => stringify(field(row, :metric_name)),
      "metric_type" => stringify(field(row, :metric_type)),
      "device_id" => stringify(field(row, :device_id)),
      "value" => field(row, :value),
      "unit" => stringify(field(row, :unit)),
      "if_index" => field(row, :if_index),
      "partition" => stringify(field(row, :partition)),
      "scale" => field(row, :scale),
      "is_delta" => field(row, :is_delta),
      "counter_width" => field(row, :counter_width),
      "target_device_ip" => stringify(field(row, :target_device_ip)),
      "tags" => json_text(field(row, :tags))
    }
  end

  defp encode_row(:logs, row) do
    %{
      "id" => Identity.record_id(:logs, row),
      "timestamp" => datetime(field(row, :timestamp)),
      "ingest_identity" => stringify(field(row, :ingest_identity) || ""),
      "severity_text" => stringify(field(row, :severity_text)),
      "severity_number" => field(row, :severity_number),
      "body" => stringify(field(row, :body)),
      "service_name" => stringify(field(row, :service_name)),
      "source" => stringify(field(row, :source)),
      "ingest_agent_id" => stringify(field(row, :ingest_agent_id)),
      "ingest_partition" => stringify(field(row, :ingest_partition)),
      "trace_id" => stringify(field(row, :trace_id)),
      "span_id" => stringify(field(row, :span_id)),
      "event_name" => stringify(field(row, :event_name)),
      "source_ip" => stringify(field(row, :source_ip)),
      "service_version" => stringify(field(row, :service_version)),
      "observed_timestamp" => datetime(field(row, :observed_timestamp))
    }
  end

  defp encode_row(:events, row) do
    %{
      "id" => Identity.record_id(:events, row),
      "time" => datetime(field(row, :time) || field(row, :event_timestamp)),
      "class_uid" => field(row, :class_uid),
      "category_uid" => field(row, :category_uid),
      "type_uid" => field(row, :type_uid),
      "activity_id" => field(row, :activity_id),
      "severity_id" => field(row, :severity_id),
      "severity" => bounded_string(:severity, field(row, :severity)),
      "source" => bounded_string(:source, field(row, :source)),
      "src_endpoint_ip" => bounded_string(:src_endpoint_ip, src_endpoint_ip(row)),
      "firewall_rule_name" => bounded_string(:firewall_rule_name, firewall_rule_name(row)),
      "source_type" => bounded_string(:source_type, source_type(row)),
      "message" => bounded_string(:message, field(row, :message)),
      "activity_name" => bounded_string(:activity_name, field(row, :activity_name)),
      "status" => bounded_string(:status, field(row, :status)),
      "status_id" => field(row, :status_id),
      "log_name" => bounded_string(:log_name, field(row, :log_name)),
      "log_provider" => bounded_string(:log_provider, field(row, :log_provider)),
      "trace_id" => bounded_string(:trace_id, field(row, :trace_id)),
      "span_id" => bounded_string(:span_id, field(row, :span_id)),
      "log_level" => bounded_string(:log_level, field(row, :log_level)),
      "metadata" => document(row, :metadata),
      "unmapped" => document(row, :unmapped),
      "device" => document(row, :device),
      "observables" => document(row, :observables)
    }
  end

  defp encode_row(:mtr_traces, row) do
    row
    |> mtr_columns(@mtr_trace_text, @mtr_trace_values)
    |> Map.merge(%{
      "id" => uuid_text(value(row, :id)),
      "time" => datetime(value(row, :time)),
      "created_at" => created_at(row)
    })
  end

  defp encode_row(:mtr_hops, row) do
    row
    |> mtr_columns(@mtr_hop_text, @mtr_hop_values)
    |> Map.merge(%{
      "id" => uuid_text(value(row, :id)),
      "time" => datetime(value(row, :time)),
      "trace_id" => uuid_text(value(row, :trace_id)),
      "ecmp_addrs" => text_list(value(row, :ecmp_addrs)),
      "mpls_labels" => json_document(value(row, :mpls_labels)),
      "created_at" => created_at(row)
    })
  end

  # priv/starrocks/0018: the documents are VARCHAR(1048576), and a value wider
  # than its column is a load error. An oversized document is dropped so the
  # event itself still lands. That event is then outside every document-path
  # filter, so the drop is reported rather than left invisible.
  @max_document_bytes 1_048_576

  # priv/starrocks/0004: the scalar event columns are bounded VARCHARs whose
  # CNPG counterparts are unbounded text. A value wider than its column makes
  # StarRocks FILTER that row out of the Stream Load batch: the row never
  # reaches the warehouse while StreamLoad.interpret_load/4 reports "filtered
  # rows" and Destination.persist_starrocks/4 still returns success. That is
  # the events-only row-count shortfall -- logs match exactly because none of
  # their columns overflow. Truncate here (UTF-8-safe) so the row always lands,
  # and report the truncation rather than leaving a silent drop.
  @scalar_limits %{
    severity: 32,
    source: 256,
    src_endpoint_ip: 64,
    firewall_rule_name: 256,
    source_type: 64,
    message: 65_533,
    activity_name: 128,
    status: 64,
    log_name: 256,
    log_provider: 128,
    trace_id: 64,
    span_id: 64,
    log_level: 32
  }

  defp bounded_string(column, value) do
    value = stringify(value)
    max = Map.fetch!(@scalar_limits, column)

    if is_binary(value) and byte_size(value) > max do
      scalar_truncated(column, byte_size(value), max)
      truncate_binary(value, max)
    else
      value
    end
  end

  defp truncate_binary(value, max_bytes) do
    value
    |> binary_part(0, max_bytes)
    |> trim_incomplete_utf8()
  end

  defp trim_incomplete_utf8(value) do
    if String.valid?(value) do
      value
    else
      trim_incomplete_utf8(binary_part(value, 0, byte_size(value) - 1))
    end
  end

  defp scalar_truncated(column, bytes, max) do
    :telemetry.execute(
      [:serviceradar, :starrocks, :events, :scalar_truncated],
      %{bytes: bytes, max_bytes: max},
      %{field: Atom.to_string(column)}
    )
  end

  defp document(row, key) do
    value = field(row, key)

    case json_text(decode_document(key, value)) do
      json when is_binary(json) and byte_size(json) <= @max_document_bytes ->
        json

      json when is_binary(json) ->
        document_dropped(key, :too_large, byte_size(json))

      nil when is_nil(value) ->
        nil

      nil ->
        document_dropped(key, :not_a_document, document_bytes(value))
    end
  end

  # OCSF observables are an array of objects; the other three are objects.
  defp decode_document(:observables, value) when is_list(value), do: value

  defp decode_document(:observables, value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, decoded} when is_list(decoded) or is_map(decoded) -> decoded
      _ -> nil
    end
  end

  defp decode_document(_key, value), do: decode_object(value)

  defp document_bytes(value) when is_binary(value), do: byte_size(value)
  defp document_bytes(_value), do: 0

  defp document_dropped(key, reason, bytes) do
    :telemetry.execute(
      [:serviceradar, :starrocks, :events, :document_dropped],
      %{bytes: bytes},
      %{field: Atom.to_string(key), reason: reason}
    )

    nil
  end

  defp field(row, key) when is_atom(key) do
    Map.get(row, key) || Map.get(row, Atom.to_string(key))
  end

  # `field/2` reads `false` as absent, which a NOT NULL boolean cannot afford.
  defp value(row, key) when is_atom(key) do
    case Map.fetch(row, key) do
      {:ok, value} -> value
      :error -> Map.get(row, Atom.to_string(key))
    end
  end

  defp mtr_columns(row, text_columns, value_columns) do
    text = Map.new(text_columns, &{Atom.to_string(&1), stringify(value(row, &1))})
    values = Map.new(value_columns, &{Atom.to_string(&1), value(row, &1)})
    Map.merge(text, values)
  end

  defp uuid_text(id) when is_binary(id) and byte_size(id) == 16 do
    case Ecto.UUID.load(id) do
      {:ok, uuid} -> uuid
      :error -> nil
    end
  end

  defp uuid_text(id), do: stringify(id)

  # The CNPG insert leaves created_at to the column default; the warehouse
  # column has none, so the load stamps it.
  defp created_at(row) do
    datetime(value(row, :created_at) || DateTime.utc_now())
  end

  defp text_list(nil), do: nil
  defp text_list(values) when is_list(values), do: Enum.map(values, &stringify/1)
  defp text_list(_values), do: nil

  # A JSON column takes the document itself; a JSON-encoded string would load
  # as a JSON string rather than an object.
  defp json_document(nil), do: nil
  defp json_document(value) when is_map(value) or is_list(value), do: value

  defp json_document(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, decoded} when is_map(decoded) or is_list(decoded) -> decoded
      _ -> nil
    end
  end

  defp json_document(_value), do: nil

  defp src_endpoint_ip(row) do
    case field(row, :src_endpoint_ip) || map_get(field(row, :src_endpoint), "ip") do
      ip when is_binary(ip) and ip != "" -> ip
      _ -> nil
    end
  end

  defp firewall_rule_name(row) do
    raw = field(row, :raw_data)

    name =
      case decode_object(raw) do
        %{} = object -> map_get(map_get(object, "firewall_rule"), "name")
        _ -> nil
      end

    if is_binary(name) and name != "", do: name
  end

  defp source_type(row) do
    metadata = field(row, :metadata) || %{}
    service = map_get(metadata, "service_radar") || map_get(metadata, "serviceradar")
    type = map_get(service, "source_type")
    if is_binary(type) and type != "", do: type
  end

  defp decode_object(%{} = object), do: object

  defp decode_object(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, %{} = object} -> object
      _ -> nil
    end
  end

  defp decode_object(_), do: nil

  defp map_get(%{} = map, key) when is_binary(key) do
    Map.get(map, key) || Map.get(map, atom_key(key))
  end

  defp map_get(_, _), do: nil

  defp atom_key("ip"), do: :ip
  defp atom_key("name"), do: :name
  defp atom_key("service_radar"), do: :service_radar
  defp atom_key("serviceradar"), do: :serviceradar
  defp atom_key("source_type"), do: :source_type
  defp atom_key("firewall_rule"), do: :firewall_rule
  defp atom_key(_), do: nil

  defp payload_text(row, key) do
    case map_get(field(row, :ocsf_payload), key) do
      value when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end

  defp connection_info_int(row, string_key, atom_alias) do
    with %{} = payload <- field(row, :ocsf_payload),
         %{} = info <- Map.get(payload, "connection_info") || Map.get(payload, :connection_info) do
      case Map.get(info, string_key) || Map.get(info, atom_alias) do
        n when is_integer(n) -> n
        n when is_binary(n) -> parse_int(n)
        _ -> nil
      end
    else
      _ -> nil
    end
  end

  defp parse_int(value) do
    case Integer.parse(value) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp json_text(nil), do: nil
  defp json_text(value) when is_binary(value), do: value

  defp json_text(value) when is_map(value) or is_list(value) do
    case Jason.encode(value) do
      {:ok, json} -> json
      _ -> nil
    end
  end

  defp json_text(_), do: nil

  defp sum_pair(a, b) when is_integer(a) and is_integer(b), do: a + b
  defp sum_pair(a, nil) when is_integer(a), do: a
  defp sum_pair(nil, b) when is_integer(b), do: b
  defp sum_pair(_, _), do: nil

  defp stringify(nil), do: nil
  defp stringify(value) when is_binary(value), do: value
  defp stringify(value), do: to_string(value)

  defp datetime(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp datetime(%NaiveDateTime{} = dt), do: NaiveDateTime.to_iso8601(dt)
  defp datetime(value) when is_binary(value), do: value
  defp datetime(nil), do: nil
  defp datetime(value), do: to_string(value)
end
