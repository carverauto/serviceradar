defmodule ServiceRadarWebNGWeb.NetflowLive.Visualize.ChartData.Sankey do
  @moduledoc false

  import ServiceRadarWebNGWeb.NetflowLive.Visualize.Format, only: [to_int: 1]
  import ServiceRadarWebNGWeb.NetflowLive.Visualize.QueryState

  alias ServiceRadarWebNGWeb.NetflowLive.ChartState
  alias ServiceRadarWebNGWeb.NetflowLive.Visualize.ChartData
  alias ServiceRadarWebNGWeb.NetflowVisualize.Query, as: NFQuery

  def load_sankey_edges(srql_module, chart_query, base, state, scope, max_edges)
      when is_integer(max_edges) and max_edges > 0 do
    prefix = sankey_prefix_from_state(state)
    dims = state |> dims_from_state() |> sanitize_sankey_dims()

    case srql_module.query(chart_query, %{scope: scope}) do
      {:ok, %{"results" => results}} when is_list(results) ->
        edges =
          results
          |> ChartData.extract_srql_rows()
          |> Enum.map(&srql_sankey_edge_from_row/1)
          |> Enum.reject(&is_nil/1)
          |> Enum.sort_by(&(-Map.get(&1, :bytes, 0)))

        if edges == [] do
          sankey =
            NFQuery.load_sankey(srql_module, base, scope,
              prefix: prefix,
              dims: dims,
              max_edges: max_edges
            )

          {Map.get(sankey, :edges, []), nil}
        else
          {edges, nil}
        end

      {:error, reason} ->
        {[], ChartState.query_error("Sankey query", reason)}

      _ ->
        sankey =
          NFQuery.load_sankey(srql_module, base, scope,
            prefix: prefix,
            dims: dims,
            max_edges: max_edges
          )

        {Map.get(sankey, :edges, []), nil}
    end
  rescue
    exception -> {[], ChartState.query_error("Sankey query", Exception.message(exception))}
  end

  def srql_sankey_edge_from_row(%{} = row) do
    other? = sankey_other_row?(row)
    {src_field, src} = sankey_endpoint(row, :src)
    {dst_field, dst} = sankey_endpoint(row, :dst)
    {mid_field, mid_value, port} = sankey_mid(row)

    bytes = to_int(Map.get(row, "total_bytes"))
    src = if other?, do: sankey_other_label(src, "Other (src)"), else: src
    dst = if other?, do: sankey_other_label(dst, "Other (dst)"), else: dst
    port = if other?, do: 0, else: port
    mid = if other?, do: "Other", else: sankey_mid_label(mid_field, mid_value, port)

    src = if is_binary(src), do: String.trim(src), else: src
    dst = if is_binary(dst), do: String.trim(dst), else: dst
    attributed_count = to_int(Map.get(row, "attributed_count"))
    ioc_count = to_int(Map.get(row, "ioc_count"))

    if is_binary(src) and src != "" and is_binary(dst) and dst != "" and bytes > 0 do
      %{
        src: src,
        mid: mid,
        port: port,
        dst: dst,
        bytes: bytes,
        src_field: src_field,
        dst_field: dst_field,
        mid_field: mid_field,
        mid_value: mid_value,
        attributed_count: attributed_count,
        ioc_count: ioc_count,
        other?: other?,
        attributed?: attributed_count > 0,
        ioc?: ioc_count > 0
      }
    end
  end

  def srql_sankey_edge_from_row(_), do: nil

  def sankey_other_row?(%{} = row), do: Map.get(row, "__other__") in [true, "true", 1, "1"]

  def sankey_other_label(value, label) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: label, else: value
  end

  def sankey_other_label(_value, label), do: label

  def sankey_endpoint(%{} = row, :src) do
    # SRQL group-by expressions can surface as different column names (e.g. "src_cidr",
    # "src_cidr:24", or aliased variants). Be tolerant so sankey charts don't go empty
    # just because a column name changed.
    find_key = fn prefix ->
      row
      |> Map.keys()
      |> Enum.find(fn
        k when is_binary(k) -> String.starts_with?(k, prefix)
        _ -> false
      end)
    end

    cidr_key = find_key.("src_cidr")
    ip_key = find_key.("src_endpoint_ip") || find_key.("src_ip")

    cond do
      is_binary(cidr_key) and is_binary(Map.get(row, cidr_key)) ->
        {"src_cidr", Map.get(row, cidr_key)}

      is_binary(ip_key) and is_binary(Map.get(row, ip_key)) ->
        {"src_ip", Map.get(row, ip_key)}

      true ->
        {nil, nil}
    end
  end

  def sankey_endpoint(%{} = row, :dst) do
    find_key = fn prefix ->
      row
      |> Map.keys()
      |> Enum.find(fn
        k when is_binary(k) -> String.starts_with?(k, prefix)
        _ -> false
      end)
    end

    cidr_key = find_key.("dst_cidr")
    ip_key = find_key.("dst_endpoint_ip") || find_key.("dst_ip")

    cond do
      is_binary(cidr_key) and is_binary(Map.get(row, cidr_key)) ->
        {"dst_cidr", Map.get(row, cidr_key)}

      is_binary(ip_key) and is_binary(Map.get(row, ip_key)) ->
        {"dst_ip", Map.get(row, ip_key)}

      true ->
        {nil, nil}
    end
  end

  def sankey_mid(%{} = row) do
    find_key = fn prefix ->
      row
      |> Map.keys()
      |> Enum.find(fn
        k when is_binary(k) -> String.starts_with?(k, prefix)
        _ -> false
      end)
    end

    port_key = find_key.("dst_endpoint_port") || find_key.("dst_port")

    cond do
      is_binary(port_key) and not is_nil(Map.get(row, port_key)) ->
        p = to_int(Map.get(row, port_key))
        {"dst_port", p, p}

      is_binary(Map.get(row, "app")) ->
        {"app", Map.get(row, "app"), 0}

      is_binary(Map.get(row, "protocol_group")) ->
        {"protocol_group", Map.get(row, "protocol_group"), 0}

      true ->
        {nil, nil, 0}
    end
  end

  def sankey_mid_label("dst_port", _mid_value, port) when is_integer(port) and port > 0, do: to_string(port)

  def sankey_mid_label(_mid_field, mid_value, _port) when is_binary(mid_value) do
    v = String.trim(mid_value)
    if v == "", do: "PORT:?", else: v
  end

  def sankey_mid_label(_mid_field, _mid_value, _port), do: "?"
end
