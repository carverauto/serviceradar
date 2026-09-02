defmodule ServiceRadarWebNGWeb.DeviceLive.FlowComponents.Formatters do
  @moduledoc false

  import ServiceRadarWebNGWeb.FlowStatComponents, only: [format_si: 1]

  def snmp_id_label(nil), do: nil
  def snmp_id_label(id) when is_integer(id), do: "if#{id}"
  def snmp_id_label(id) when is_binary(id) and id != "", do: "if#{id}"
  def snmp_id_label(_), do: nil

  def flow_endpoint(flow, :src), do: Map.get(flow, "src_endpoint_ip") || "—"
  def flow_endpoint(flow, :dst), do: Map.get(flow, "dst_endpoint_ip") || "—"

  def iso2_flag_emoji(nil), do: nil

  def iso2_flag_emoji(iso2) when is_binary(iso2) do
    iso2 = iso2 |> String.trim() |> String.upcase()

    if String.length(iso2) == 2 do
      <<a::utf8, b::utf8>> = iso2
      if a in ?A..?Z and b in ?A..?Z, do: <<0x1F1E6 + (a - ?A)::utf8, 0x1F1E6 + (b - ?A)::utf8>>
    end
  end

  def iso2_flag_emoji(_), do: nil

  def flow_protocol(flow) do
    protocol_label(Map.get(flow, "protocol_num"), Map.get(flow, "protocol_name"))
  end

  def flow_service_label(flow) when is_map(flow) do
    case Map.get(flow, "dst_service_label") do
      service when is_binary(service) and service != "" -> service
      _ -> nil
    end
  end

  def flow_exporter_name(flow) when is_map(flow) do
    case Map.get(flow, "exporter_name") do
      name when is_binary(name) and name != "" -> name
      _ -> nil
    end
  end

  def flow_format_number(nil), do: "—"
  def flow_format_number(n) when is_number(n), do: format_si(n)
  def flow_format_number(_), do: "—"

  def flow_port(flow, :src) do
    case Map.get(flow, "src_endpoint_port") do
      port when is_integer(port) -> ":#{port}"
      _ -> ""
    end
  end

  def flow_port(flow, :dst) do
    case Map.get(flow, "dst_endpoint_port") do
      port when is_integer(port) -> ":#{port}"
      _ -> ""
    end
  end

  def flow_time(flow) do
    Map.get(flow, "time") || Map.get(flow, "timestamp")
  end

  def flow_drilldown_query(flow) when is_map(flow) do
    tokens =
      ["in:flows", "time:last_24h"]
      |> maybe_add_flow_token("src_ip", Map.get(flow, "src_endpoint_ip"))
      |> maybe_add_flow_token("dst_ip", Map.get(flow, "dst_endpoint_ip"))
      |> maybe_add_flow_token("src_port", Map.get(flow, "src_endpoint_port"))
      |> maybe_add_flow_token("dst_port", Map.get(flow, "dst_endpoint_port"))
      |> maybe_add_flow_token("proto", Map.get(flow, "protocol_num"))
      |> Kernel.++(["sort:time:desc"])

    Enum.join(tokens, " ")
  end

  def maybe_add_flow_token(tokens, _field, nil), do: tokens
  def maybe_add_flow_token(tokens, _field, ""), do: tokens

  def maybe_add_flow_token(tokens, field, value) do
    value = value |> to_string() |> String.trim()

    if value == "" do
      tokens
    else
      tokens ++ ["#{field}:#{flow_query_value(value)}"]
    end
  end

  def flow_query_value(value) when is_binary(value) do
    if String.contains?(value, [" ", ":", "\""]) do
      ~s|"#{String.replace(value, "\"", "\\\"")}"|
    else
      value
    end
  end

  def parse_datetime(%DateTime{} = dt), do: {:ok, dt}

  def parse_datetime(%NaiveDateTime{} = ndt) do
    DateTime.from_naive(ndt, "Etc/UTC")
  end

  def parse_datetime(value) when is_binary(value), do: DateTime.from_iso8601(value)
  def parse_datetime(_), do: {:error, :invalid_datetime}

  def format_bytes(bytes) when is_number(bytes) do
    cond do
      bytes >= 1_099_511_627_776 -> "#{Float.round(bytes / 1_099_511_627_776 * 1.0, 1)} TB"
      bytes >= 1_073_741_824 -> "#{Float.round(bytes / 1_073_741_824 * 1.0, 1)} GB"
      bytes >= 1_048_576 -> "#{Float.round(bytes / 1_048_576 * 1.0, 1)} MB"
      bytes >= 1024 -> "#{Float.round(bytes / 1024 * 1.0, 1)} KB"
      true -> "#{bytes} B"
    end
  end

  def format_bytes(_), do: "—"

  def protocol_label(protocol_num, protocol_name) do
    case parse_protocol_num(protocol_num) do
      1 -> "ICMP"
      6 -> "TCP"
      17 -> "UDP"
      47 -> "GRE"
      50 -> "ESP"
      51 -> "AH"
      58 -> "ICMPv6"
      89 -> "OSPF"
      132 -> "SCTP"
      n when is_integer(n) -> normalized_protocol_name(protocol_name) || "proto #{n}"
      nil -> normalized_protocol_name(protocol_name) || "unknown"
    end
  end

  def parse_protocol_num(n) when is_integer(n), do: n

  def parse_protocol_num(n) when is_binary(n) do
    case Integer.parse(String.trim(n)) do
      {value, ""} -> value
      _ -> nil
    end
  end

  def parse_protocol_num(_), do: nil

  def normalized_protocol_name(name) when is_binary(name) do
    name = String.trim(name)
    if name == "", do: nil, else: String.upcase(name)
  end

  def normalized_protocol_name(_), do: nil

  def flow_stat_field(payload, key) when is_map(payload) do
    Map.get(payload, key) || Map.get(payload, String.to_existing_atom(key))
  rescue
    ArgumentError -> Map.get(payload, key)
  end

  def flow_stat_number(payload, key) do
    case flow_stat_field(payload, key) do
      n when is_number(n) ->
        n

      s when is_binary(s) ->
        case Float.parse(s) do
          {f, _} -> f
          :error -> 0
        end

      _ ->
        0
    end
  end

  def to_safe_number(n) when is_number(n), do: n
  def to_safe_number(nil), do: 0

  def to_safe_number(s) when is_binary(s) do
    case Float.parse(s) do
      {f, _} -> f
      :error -> 0
    end
  end

  def to_safe_number(_), do: 0
end
