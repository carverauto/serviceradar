defmodule ServiceRadar.Analytics.StarRocks.Rows do
  @moduledoc """
  Maps EventWriter-decoded rows onto StarRocks Stream Load JSON documents.
  """

  alias ServiceRadar.Analytics.StarRocks.Identity

  @type dataset :: Identity.dataset()

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
      "severity" => stringify(field(row, :severity)),
      "source" => stringify(field(row, :source)),
      "src_endpoint_ip" => stringify(src_endpoint_ip(row)),
      "firewall_rule_name" => stringify(firewall_rule_name(row)),
      "source_type" => stringify(source_type(row)),
      "message" => stringify(field(row, :message)),
      "activity_name" => stringify(field(row, :activity_name)),
      "status" => stringify(field(row, :status)),
      "status_id" => field(row, :status_id),
      "log_name" => stringify(field(row, :log_name)),
      "log_provider" => stringify(field(row, :log_provider)),
      "trace_id" => stringify(field(row, :trace_id)),
      "span_id" => stringify(field(row, :span_id)),
      "log_level" => stringify(field(row, :log_level)),
      "metadata" => document(field(row, :metadata)),
      "unmapped" => document(field(row, :unmapped)),
      "device" => document(field(row, :device))
    }
  end

  # priv/starrocks/0018: the documents are VARCHAR(1048576), and a value wider
  # than its column is a load error. An oversized document is dropped so the
  # event itself still lands.
  @max_document_bytes 1_048_576

  defp document(value) do
    case json_text(decode_object(value)) do
      json when is_binary(json) and byte_size(json) <= @max_document_bytes -> json
      _ -> nil
    end
  end

  defp field(row, key) when is_atom(key) do
    Map.get(row, key) || Map.get(row, Atom.to_string(key))
  end

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
