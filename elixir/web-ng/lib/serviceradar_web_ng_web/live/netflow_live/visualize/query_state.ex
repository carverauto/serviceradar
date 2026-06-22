defmodule ServiceRadarWebNGWeb.NetflowLive.Visualize.QueryState do
  @moduledoc false

  alias ServiceRadarWebNGWeb.NetflowLive.Visualize.Config
  alias ServiceRadarWebNGWeb.NetflowVisualize.Query, as: NFQuery

  @default_time Config.default_time()
  @default_bucket Config.default_bucket()
  @chart_limit Config.chart_limit()
  @sankey_src_dims Config.sankey_src_dims()
  @sankey_mid_dims Config.sankey_mid_dims()
  @sankey_dst_dims Config.sankey_dst_dims()

  def chart_query_from_state(base_query, %{} = state) do
    time = Map.get(state, "time", @default_time)
    base = chart_base_query(base_query, time)
    graph = Map.get(state, "graph", "stacked")
    dims = dims_from_state(state)
    dims = if graph == "sankey", do: sanitize_sankey_dims(dims), else: dims

    state = Map.put(state, "dims", dims)

    case graph do
      "sankey" -> chart_query_sankey(base, state)
      _ -> chart_query_timeseries(base, state)
    end
  end

  def chart_base_query(base_query, time_token) when is_binary(time_token) do
    # Visualize state is the SRQL emitter. When the user changes the time dropdown,
    # we must override any existing `time:` token in the working base query.
    base_query
    |> to_string()
    |> NFQuery.flows_base_query(time_token)
    |> NFQuery.flows_replace_time(time_token)
    |> NFQuery.flows_sanitize_for_stats()
    |> String.trim()
  end

  def chart_query_sankey(base, %{} = state) when is_binary(base) do
    prefix = sankey_prefix_from_state(state)
    cidr_prefix = if prefix == 32, do: 24, else: prefix
    dims = state |> dims_from_state() |> sanitize_sankey_dims()

    src_dim = Enum.at(dims, 0)
    mid_dim = Enum.at(dims, 1)
    dst_dim = Enum.at(dims, 2)

    src = sankey_src_group_by(src_dim, cidr_prefix)
    mid = sankey_mid_group_by(mid_dim)
    dst = sankey_dst_group_by(dst_dim, cidr_prefix)
    limit = sankey_max_edges_from_state(state)

    ~s|#{base} stats:"sum(bytes_total) as total_bytes by #{src}, #{mid}, #{dst}" sort:total_bytes:desc limit:#{limit} other:true|
  end

  def chart_query_timeseries(base, %{} = state) when is_binary(base) do
    units = Map.get(state, "units", "Bps")
    dims = dims_from_state(state)
    series_limit = Map.get(state, "limit", 12)

    value_field = if units == "pps", do: "packets_total", else: "bytes_total"
    series_field = NFQuery.downsample_series_field_from_dims(dims)
    limit = max(@chart_limit, series_limit * 200)

    ~s|#{base} bucket:#{@default_bucket} agg:sum value_field:#{value_field} series:#{series_field} limit:#{limit}|
  end

  def dims_from_state(%{} = state) do
    state
    |> Map.get("dims", [])
    |> List.wrap()
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  def normalize_state_for_graph(%{} = state) do
    if Map.get(state, "graph") == "sankey" do
      dims = state |> dims_from_state() |> sanitize_sankey_dims()
      Map.put(state, "dims", dims)
    else
      state
    end
  end

  def sanitize_sankey_dims(dims) when is_list(dims) do
    src_allowed = Enum.map(@sankey_src_dims, fn {_l, v} -> v end)
    mid_allowed = Enum.map(@sankey_mid_dims, fn {_l, v} -> v end)
    dst_allowed = Enum.map(@sankey_dst_dims, fn {_l, v} -> v end)

    src = Enum.find(dims, &(&1 in src_allowed)) || "src_cidr"
    mid = Enum.find(dims, &(&1 in mid_allowed)) || "dst_port"
    dst = Enum.find(dims, &(&1 in dst_allowed)) || "dst_cidr"
    [src, mid, dst]
  end

  def dim_human_label(nil), do: ""
  def dim_human_label(""), do: ""

  def dim_human_label(dim) when is_binary(dim) do
    case String.trim(dim) do
      "src_ip" -> "Source IP"
      "src_cidr" -> "Source CIDR"
      "dst_ip" -> "Destination IP"
      "dst_cidr" -> "Destination CIDR"
      "dst_port" -> "Destination Port"
      "app" -> "Application"
      "protocol_group" -> "Protocol"
      "protocol_name" -> "Protocol"
      other -> other
    end
  end

  def dim_human_label(other), do: to_string(other || "")

  def sankey_max_edges_from_state(%{} = state) do
    # Each edge is rendered as 2 links (src->mid, mid->dst). Keep the sankey readable.
    n =
      case Map.get(state, "limit") do
        i when is_integer(i) ->
          i

        s when is_binary(s) ->
          case Integer.parse(String.trim(s)) do
            {i, ""} -> i
            _ -> 12
          end

        _ ->
          12
      end

    n = max(n, 1)
    max(min(n * 2, 60), 20)
  end

  def sankey_src_group_by("src_ip", _cidr_prefix), do: "src_endpoint_ip"
  def sankey_src_group_by("src_cidr", cidr_prefix), do: "src_cidr:#{cidr_prefix}"
  def sankey_src_group_by(_, cidr_prefix), do: "src_cidr:#{cidr_prefix}"

  def sankey_dst_group_by("dst_ip", _cidr_prefix), do: "dst_endpoint_ip"
  def sankey_dst_group_by("dst_cidr", cidr_prefix), do: "dst_cidr:#{cidr_prefix}"
  def sankey_dst_group_by(_, cidr_prefix), do: "dst_cidr:#{cidr_prefix}"

  def sankey_mid_group_by("dst_port"), do: "dst_endpoint_port"
  def sankey_mid_group_by("app"), do: "app"
  def sankey_mid_group_by("protocol_group"), do: "protocol_group"
  def sankey_mid_group_by(_), do: "dst_endpoint_port"

  def sankey_prefix_from_state(%{} = state) do
    case Map.get(state, "truncate_v4", 24) do
      16 -> 16
      24 -> 24
      32 -> 32
      _ -> 24
    end
  end

  def flows_list_base_query(query, fallback_time) when is_binary(fallback_time) do
    query
    |> to_string()
    |> NFQuery.flows_base_query(fallback_time)
    |> NFQuery.flows_sanitize_for_stats()
    |> String.trim()
  end
end
