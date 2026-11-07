defmodule ServiceRadar.Analytics.StarRocks.Rows do
  @moduledoc """
  Maps EventWriter-decoded rows onto StarRocks Stream Load JSON documents.
  """

  alias ServiceRadar.Analytics.StarRocks.Identity

  @type dataset ::
          Identity.dataset()
          | :mtr_traces
          | :mtr_hops
          | :otel_metrics
          | :otel_metric_points
          | :otel_traces
          | :bmp_routing_events
          | :flow_attribution_observations
          | :exposure_facts
          | :exposure_snapshot_facts
          | :exposure_compacted_facts
          | :exposure_transitions_log
          | :exposure_cve_dim
          | :exposure_package_dim
          | :exposure_retired_ordinals

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

  # priv/starrocks/0021: every column of platform.otel_metrics /
  # platform.otel_metric_points under the same name, as built by the
  # OtelMetrics processor for its CNPG insert.
  @otel_metric_text ~w(trace_id span_id service_name span_name span_kind metric_type
                       http_method http_route http_status_code grpc_service grpc_method
                       grpc_status_code component level unit ingest_identity
                       ingest_agent_id ingest_partition)a

  @otel_metric_values ~w(duration_ms duration_seconds is_slow)a

  @otel_point_text ~w(metric_name metric_type unit temporality service_name attributes
                      attributes_hash bucket_counts explicit_bounds scope_name
                      service_instance_id ingest_identity ingest_agent_id
                      ingest_partition)a

  @otel_point_values ~w(is_monotonic value count sum start_time_unix_nano)a

  # priv/starrocks/0022: every column of platform.otel_traces under the same
  # name, as built by the OtelTraces processor. Its key is the CNPG primary key.
  @otel_span_identifiers ~w(trace_id span_id parent_span_id)a

  @otel_span_text ~w(trace_state name service_name service_version service_instance
                     service_namespace deployment_environment scope_name scope_version
                     scope_attributes status_message attributes resource_attributes
                     events links ingest_identity ingest_agent_id ingest_partition)a

  @otel_span_values ~w(kind start_time_unix_nano end_time_unix_nano status_code
                       dropped_attributes_count dropped_events_count dropped_links_count)a

  # Live event-owned exposure fact columns (migrations 0032 and 0034).
  # A live after-image must never overwrite the snapshot generation.
  @exposure_fact_columns ~w(device_lifecycle_seq device_ord cve_ord pkg_ord pkgver_ord state source_scope
                            severity_rank cvss_score kev exploit_available fix_available
                            first_exposed_at resolved_at updated_at transition_seq transition_xid)

  @doc "Columns supplied by a live assessment transition, excluding the snapshot marker."
  def exposure_fact_columns, do: @exposure_fact_columns

  @doc "Fact load columns, including the warehouse-only compaction marker."
  def exposure_fact_load_columns, do: @exposure_fact_columns ++ ["payload_compacted"]

  # trace_id and span_id are the span's NOT NULL warehouse key
  # (priv/starrocks/0022). One stored as NULL because it was wider than its
  # identifier (already counted as :scalar_invalid) would be filtered by Stream
  # Load and fail every span in the load, so that span is left out instead.
  @spec encode(dataset(), [map()]) :: [map()]
  def encode(:otel_traces, rows) when is_list(rows) do
    rows
    |> Enum.map(&encode_row(:otel_traces, &1))
    |> Enum.reject(&(is_nil(&1["trace_id"]) or is_nil(&1["span_id"])))
  end

  def encode(dataset, rows) when is_list(rows) do
    Enum.map(rows, &encode_row(dataset, &1))
  end

  defp encode_row(dataset, row) when dataset in [:exposure_facts, :exposure_compacted_facts] do
    row |> Map.take(exposure_fact_load_columns()) |> Map.put_new("payload_compacted", false)
  end

  defp encode_row(:exposure_snapshot_facts, row) do
    row
    |> Map.take(exposure_fact_load_columns() ++ ["snapshot_generation"])
    |> Map.put_new("payload_compacted", false)
  end

  defp encode_row(dataset, row)
       when dataset in [
              :exposure_transitions_log,
              :exposure_cve_dim,
              :exposure_package_dim,
              :exposure_retired_ordinals
            ],
       do: row

  defp encode_row(:flow_attribution, row) do
    %{
      "id" => Identity.record_id(:flow_attribution, row),
      "time" => datetime(field(row, :time)),
      "event_type" => "attributed_flow",
      "attribution_version" => field(row, :attribution_version),
      "agent_id" => stringify(field(row, :agent_id)),
      "pid" => field(row, :pid),
      "uid" => field(row, :uid),
      "container_id" => stringify(field(row, :container_id)),
      "public_endpoint" => json_text(field(row, :public_endpoint)),
      "comm" => stringify(field(row, :comm)),
      "cmdline" => stringify(field(row, :cmdline)),
      "workload_identity" => json_text(field(row, :workload_identity))
    }
  end

  defp encode_row(:flow_attribution_observations, row) do
    %{
      "observed_at" => datetime(value(row, :observed_at)),
      "partition" => stringify(value(row, :partition)),
      "proto" => value(row, :proto),
      "local_ip" => stringify(value(row, :local_ip)),
      "local_port" => value(row, :local_port),
      "remote_ip" => stringify(value(row, :remote_ip)),
      "remote_port" => value(row, :remote_port),
      "agent_id" => identifier(:flow_attribution_observations, :agent_id, value(row, :agent_id)),
      "attribution_key" => stringify(value(row, :attribution_key)),
      "pid" => value(row, :pid),
      "comm" => text(:flow_attribution_observations, :comm, value(row, :comm)),
      "cmdline" => text(:flow_attribution_observations, :cmdline, value(row, :cmdline)),
      "uid" => value(row, :uid),
      "container_id" =>
        identifier(:flow_attribution_observations, :container_id, value(row, :container_id)),
      "workload_identity" =>
        text(
          :flow_attribution_observations,
          :workload_identity,
          json_text(value(row, :workload_identity))
        ),
      "executable_ownership" =>
        text(
          :flow_attribution_observations,
          :executable_ownership,
          json_text(value(row, :executable_ownership))
        )
    }
  end

  defp encode_row(:flows, row) do
    attribution = map_get(field(row, :ocsf_payload), "attribution")

    %{
      "id" => Identity.record_id(:flows, row),
      "device_uid" => stringify(field(row, :device_uid) || field(row, :device_id) || "unknown"),
      "agent_id" => stringify(field(row, :agent_id) || payload_text(row, "agent_id")),
      "pid" => field(row, :pid) || map_get(attribution, "pid"),
      "uid" => field(row, :uid) || map_get(attribution, "uid"),
      "container_id" =>
        stringify(field(row, :container_id) || map_get(attribution, "container_id")),
      "public_endpoint" =>
        json_text(field(row, :public_endpoint) || map_get(attribution, "public_endpoint")),
      "flow_source" => stringify(field(row, :flow_source) || payload_text(row, "flow_source")),
      "comm" => stringify(field(row, :comm) || map_get(attribution, "comm")),
      "cmdline" =>
        stringify(
          field(row, :cmdline) || map_get(attribution, "redacted_cmdline") ||
            map_get(attribution, "cmdline")
        ),
      "workload_identity" =>
        json_text(field(row, :workload_identity) || map_get(attribution, "workload_identity")),
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
      "app" => stringify(field(row, :app)),
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
      "is_delta" => value(row, :is_delta),
      "counter_width" => field(row, :counter_width),
      "target_device_ip" => stringify(field(row, :target_device_ip)),
      "tags" => json_text(field(row, :tags))
    }
  end

  defp encode_row(:logs, row) do
    %{
      "id" => Identity.record_id(:logs, row),
      "timestamp" => datetime(field(row, :timestamp)),
      "ingest_identity" => text(:logs, :ingest_identity, field(row, :ingest_identity) || ""),
      "severity_text" => text(:logs, :severity_text, field(row, :severity_text)),
      "severity_number" => field(row, :severity_number),
      "body" => text(:logs, :body, field(row, :body)),
      "service_name" => text(:logs, :service_name, field(row, :service_name)),
      "source" => text(:logs, :source, field(row, :source)),
      "ingest_agent_id" => text(:logs, :ingest_agent_id, field(row, :ingest_agent_id)),
      "ingest_partition" => text(:logs, :ingest_partition, field(row, :ingest_partition)),
      "trace_id" => identifier(:logs, :trace_id, field(row, :trace_id)),
      "span_id" => identifier(:logs, :span_id, field(row, :span_id)),
      "event_name" => text(:logs, :event_name, field(row, :event_name)),
      "source_ip" => identifier(:logs, :source_ip, field(row, :source_ip)),
      "service_version" => text(:logs, :service_version, field(row, :service_version)),
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
      "severity" => text(:events, :severity, field(row, :severity)),
      "source" => text(:events, :source, field(row, :source)),
      "src_endpoint_ip" => identifier(:events, :src_endpoint_ip, src_endpoint_ip(row)),
      "firewall_rule_name" => text(:events, :firewall_rule_name, firewall_rule_name(row)),
      "source_type" => text(:events, :source_type, source_type(row)),
      "message" => text(:events, :message, field(row, :message)),
      "activity_name" => text(:events, :activity_name, field(row, :activity_name)),
      "status" => text(:events, :status, field(row, :status)),
      "status_id" => field(row, :status_id),
      "log_name" => text(:events, :log_name, field(row, :log_name)),
      "log_provider" => text(:events, :log_provider, field(row, :log_provider)),
      "trace_id" => identifier(:events, :trace_id, field(row, :trace_id)),
      "span_id" => identifier(:events, :span_id, field(row, :span_id)),
      "log_level" => text(:events, :log_level, field(row, :log_level)),
      "metadata" => document(row, :metadata),
      "unmapped" => document(row, :unmapped),
      "device" => document(row, :device),
      "observables" => document(row, :observables),
      "actor" => document(row, :actor),
      "src_endpoint" => document(row, :src_endpoint),
      "dst_endpoint" => document(row, :dst_endpoint),
      "status_code" => text(:events, :status_code, field(row, :status_code)),
      "status_detail" => text(:events, :status_detail, field(row, :status_detail)),
      "log_version" => text(:events, :log_version, field(row, :log_version)),
      "raw_data" => text(:events, :raw_data, field(row, :raw_data)),
      "created_at" => datetime(field(row, :created_at))
    }
  end

  # The id stands for the rest of the CNPG primary key; with `timestamp` it is
  # the warehouse key, so the pair enforces the uniqueness CNPG does.
  defp encode_row(:otel_metrics, row) do
    row
    |> mtr_columns(@otel_metric_text, @otel_metric_values)
    |> Map.merge(%{
      "id" => key_id([value(row, :span_name), value(row, :service_name), value(row, :span_id)]),
      "timestamp" => datetime(value(row, :timestamp)),
      "created_at" => created_at(row)
    })
  end

  defp encode_row(:otel_metric_points, row) do
    row
    |> mtr_columns(@otel_point_text, @otel_point_values)
    |> Map.merge(%{
      "id" =>
        key_id([
          value(row, :metric_name),
          value(row, :service_name),
          value(row, :attributes_hash)
        ]),
      "timestamp" => datetime(value(row, :timestamp)),
      "created_at" => created_at(row)
    })
  end

  defp encode_row(:otel_traces, row) do
    identifiers =
      Map.new(
        @otel_span_identifiers,
        &{Atom.to_string(&1), identifier(:otel_traces, &1, value(row, &1))}
      )

    text =
      Map.new(@otel_span_text, &{Atom.to_string(&1), text(:otel_traces, &1, value(row, &1))})

    values = Map.new(@otel_span_values, &{Atom.to_string(&1), value(row, &1)})

    identifiers
    |> Map.merge(text)
    |> Map.merge(values)
    |> Map.merge(%{
      "timestamp" => datetime(value(row, :timestamp)),
      "created_at" => created_at(row)
    })
  end

  defp encode_row(:bmp_routing_events, row) do
    %{
      "id" => uuid_text(value(row, :id)),
      "time" => datetime(value(row, :time)),
      "event_type" => text(:bmp_routing_events, :event_type, value(row, :event_type)),
      "severity_id" => value(row, :severity_id),
      "router_id" => identifier(:bmp_routing_events, :router_id, value(row, :router_id)),
      "router_ip" => identifier(:bmp_routing_events, :router_ip, value(row, :router_ip)),
      "peer_ip" => identifier(:bmp_routing_events, :peer_ip, value(row, :peer_ip)),
      "peer_asn" => value(row, :peer_asn),
      "local_asn" => value(row, :local_asn),
      "prefix" => identifier(:bmp_routing_events, :prefix, value(row, :prefix)),
      "message" => text(:bmp_routing_events, :message, value(row, :message)),
      "metadata" => json_document(value(row, :metadata)),
      "raw_data" => text(:bmp_routing_events, :raw_data, value(row, :raw_data)),
      "created_at" => created_at(row)
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

  # Identifier columns keep the width their protocol allows (priv/starrocks/0003,
  # 0004, 0022, 0024, 0026): a W3C trace id is 32 hex characters, a span id 16,
  # an IP address at most 45, all within their columns. A wider value is not
  # that identifier, and a cut one would name a different trace, span, router,
  # prefix, agent or container, so it is stored as NULL and counted, never
  # truncated.
  @identifier_limits %{
    bmp_routing_events: %{router_id: 256, router_ip: 64, peer_ip: 64, prefix: 128},
    events: %{src_endpoint_ip: 64, trace_id: 64, span_id: 64},
    flow_attribution_observations: %{agent_id: 256, container_id: 256},
    logs: %{trace_id: 64, span_id: 64, source_ip: 64},
    otel_traces: %{trace_id: 32, span_id: 16, parent_span_id: 16}
  }

  defp identifier(dataset, column, value) do
    value = stringify(value)
    max = @identifier_limits |> Map.fetch!(dataset) |> Map.fetch!(column)

    if is_binary(value) and byte_size(value) > max do
      :telemetry.execute(
        [:serviceradar, :starrocks, dataset, :scalar_invalid],
        %{bytes: byte_size(value), max_bytes: max},
        %{field: Atom.to_string(column)}
      )

      nil
    else
      value
    end
  end

  # Free text has no bound in CNPG, and its warehouse column is VARCHAR(1048576)
  # (priv/starrocks/0037, 0041): one NATS message (1 MiB max_payload as shipped)
  # cannot carry more, so the value is stored whole. One wider than the column
  # is dropped from its field and reported, as an oversized document is, rather
  # than cut, so the row still lands.
  defp text(dataset, column, value) do
    case stringify(value) do
      value when is_binary(value) and byte_size(value) > @max_document_bytes ->
        document_dropped(dataset, column, :too_large, byte_size(value))

      value ->
        value
    end
  end

  defp document(row, key) do
    value = field(row, key)

    case json_text(decode_document(key, value)) do
      json when is_binary(json) and byte_size(json) <= @max_document_bytes ->
        json

      json when is_binary(json) ->
        document_dropped(:events, key, :too_large, byte_size(json))

      nil when is_nil(value) ->
        nil

      nil ->
        document_dropped(:events, key, :not_a_document, document_bytes(value))
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

  defp document_dropped(dataset, key, reason, bytes) do
    :telemetry.execute(
      [:serviceradar, :starrocks, dataset, :document_dropped],
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

  # SHA-256 over the key parts, length-prefixed so ("ab", "c") and ("a", "bc")
  # differ and nil differs from "".
  defp key_id(parts) do
    parts
    |> Enum.map_join(fn
      nil -> "-"
      part -> "+" <> Integer.to_string(byte_size(stringify(part))) <> ":" <> stringify(part)
    end)
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
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
