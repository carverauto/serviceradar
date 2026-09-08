defmodule ServiceRadarWebNGWeb.NetflowLive.Visualize.Filters do
  @moduledoc false

  def parse_optional_port(nil), do: nil
  def parse_optional_port(""), do: nil

  def parse_optional_port(port_raw) do
    case Integer.parse(to_string(port_raw)) do
      {n, ""} when n > 0 -> n
      _ -> nil
    end
  end

  def apply_endpoint_filter(query, _side, nil), do: query

  def apply_endpoint_filter(query, :src, value) when is_binary(value) do
    if String.contains?(value, "/") do
      upsert_query_filter(query, "src_cidr", value)
    else
      upsert_query_filter(query, "src_ip", value)
    end
  end

  def apply_endpoint_filter(query, :dst, value) when is_binary(value) do
    if String.contains?(value, "/") do
      upsert_query_filter(query, "dst_cidr", value)
    else
      upsert_query_filter(query, "dst_ip", value)
    end
  end

  def apply_mid_filter(query, nil, _mid_value, _port), do: query

  def apply_mid_filter(query, mid_field, mid_value, port) when is_binary(mid_field) do
    case mid_field do
      f when f in ["dst_port", "dst_endpoint_port"] ->
        cond do
          is_integer(port) ->
            upsert_query_filter(query, "dst_port", to_string(port))

          is_binary(mid_value) and mid_value != "" ->
            upsert_query_filter(query, "dst_port", mid_value)

          true ->
            query
        end

      "app" when is_binary(mid_value) and mid_value != "" ->
        upsert_query_filter(query, "app", mid_value)

      "protocol_group" when is_binary(mid_value) and mid_value != "" ->
        upsert_query_filter(query, "protocol_group", mid_value)

      _ ->
        query
    end
  end

  def flows_filter_patch(base_path, query, _limit, nf, field, value) do
    value = (value || "") |> to_string() |> String.trim()

    q = upsert_query_filter(query || "", field, value)

    params =
      %{"q" => q, "nf" => nf}
      |> Enum.reject(fn {_k, v} -> is_nil(v) or v == "" end)
      |> Map.new()

    base_path <> "?" <> URI.encode_query(params)
  end

  def upsert_query_filter(query, field, value) when is_binary(query) and is_binary(field) do
    pattern = ~r/(?:^|\s)#{Regex.escape(field)}:(?:"([^"]+)"|(\S+))/

    query =
      query
      |> String.replace(pattern, "")
      |> String.replace(~r/\s+/, " ")
      |> String.trim()

    if String.trim(to_string(value || "")) == "" do
      query
    else
      String.trim(query <> " " <> "#{field}:#{value}")
    end
  end
end
