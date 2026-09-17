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
      "attribution_version" => field(row, :attribution_version),
      "pid" => field(row, :pid),
      "comm" => stringify(field(row, :comm)),
      "cmdline" => stringify(field(row, :cmdline)),
      "workload_identity" => stringify(field(row, :workload_identity))
    }
  end

  defp encode_row(:flows, row) do
    %{
      "id" => Identity.record_id(:flows, row),
      "device_uid" => stringify(field(row, :device_uid) || field(row, :device_id) || "unknown"),
      "time" => datetime(field(row, :time)),
      "src_endpoint_ip" => stringify(field(row, :src_endpoint_ip)),
      "dst_endpoint_ip" => stringify(field(row, :dst_endpoint_ip)),
      "src_endpoint_port" => field(row, :src_endpoint_port),
      "dst_endpoint_port" => field(row, :dst_endpoint_port),
      "protocol_num" => field(row, :protocol_num),
      "protocol_name" => stringify(field(row, :protocol_name)),
      "direction_label" => stringify(field(row, :direction_label)),
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
      "counter_width" => field(row, :counter_width)
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
      "ingest_partition" => stringify(field(row, :ingest_partition))
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
      "source_type" => stringify(source_type(row))
    }
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

  defp stringify(nil), do: nil
  defp stringify(value) when is_binary(value), do: value
  defp stringify(value), do: to_string(value)

  defp datetime(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp datetime(%NaiveDateTime{} = dt), do: NaiveDateTime.to_iso8601(dt)
  defp datetime(value) when is_binary(value), do: value
  defp datetime(nil), do: nil
  defp datetime(value), do: to_string(value)
end
