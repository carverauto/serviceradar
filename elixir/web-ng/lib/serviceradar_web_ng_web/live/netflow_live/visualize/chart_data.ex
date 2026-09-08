defmodule ServiceRadarWebNGWeb.NetflowLive.Visualize.ChartData do
  @moduledoc false

  import Phoenix.Component, only: [assign: 3]
  import ServiceRadarWebNGWeb.NetflowLive.Visualize.Format, only: [to_float: 1, to_number: 1]
  import ServiceRadarWebNGWeb.NetflowLive.Visualize.QueryState

  alias ServiceRadarWebNGWeb.NetflowLive.ChartState
  alias ServiceRadarWebNGWeb.NetflowLive.Visualize.ChartData.Overlays
  alias ServiceRadarWebNGWeb.NetflowLive.Visualize.ChartData.Sankey
  alias ServiceRadarWebNGWeb.NetflowLive.Visualize.Config
  alias ServiceRadarWebNGWeb.NetflowVisualize.Query, as: NFQuery

  @default_time Config.default_time()
  @default_bucket Config.default_bucket()
  @chart_limit Config.chart_limit()

  def units_to_value_field_and_scale("pps", bucket), do: {"packets_total", rate_scale_fun(bucket, 1.0)}

  def units_to_value_field_and_scale("bps", bucket), do: {"bytes_total", rate_scale_fun(bucket, 8.0)}

  def units_to_value_field_and_scale("Bps", bucket), do: {"bytes_total", rate_scale_fun(bucket, 1.0)}

  def units_to_value_field_and_scale(_, bucket), do: {"bytes_total", rate_scale_fun(bucket, 1.0)}

  def rate_scale_fun(bucket, multiplier) when is_binary(bucket) and is_number(multiplier) do
    secs = bucket_to_seconds(bucket)
    fn v -> to_float(v) * multiplier / secs end
  end

  def bucket_to_seconds("1m"), do: 60
  def bucket_to_seconds("5m"), do: 300
  def bucket_to_seconds("1h"), do: 3600
  def bucket_to_seconds(_), do: 300

  def load_visualize_chart(socket, chart_query, %{} = state) when is_binary(chart_query) do
    srql_module = Application.get_env(:serviceradar_web_ng, :srql_module, ServiceRadarWebNG.SRQL)
    scope = socket.assigns.current_scope

    graph = Map.get(state, "graph", "stacked")
    fallback_time = Map.get(state, "time", @default_time)
    units = Map.get(state, "units", "Bps")
    dims = Map.get(state, "dims", [])
    series_limit = Map.get(state, "limit", 12)
    limit_type = Map.get(state, "limit_type", "avg")
    bidirectional = Map.get(state, "bidirectional", false) == true
    previous_period = Map.get(state, "previous_period", false) == true

    # IMPORTANT: `chart_query` may already be a downsample/stats query; for fallbacks we need a
    # "base flows" query without chart tokens. Preserve explicit `time:` from query when present.
    base = flows_list_base_query(chart_query, fallback_time)

    case graph do
      "sankey" ->
        max_edges = sankey_max_edges_from_state(state)

        {edges, load_empty_state} = Sankey.load_sankey_edges(srql_module, chart_query, base, state, scope, max_edges)

        edges_json = Jason.encode!(edges)

        socket
        |> assign(:netflow_sankey_edges_json, edges_json)
        |> assign(:netflow_chart_overlays_json, "[]")
        |> assign(:netflow_chart_empty_state, load_empty_state || ChartState.for_sankey_edges(edges))

      _ ->
        # Charts are SRQL-driven: the SRQL query in the top bar is the chart query.
        {keys, points, load_empty_state} =
          case srql_module.query(chart_query, %{scope: scope}) do
            {:ok, %{"results" => results}} when is_list(results) ->
              {keys, points} = downsample_from_results(results)
              {keys, points, nil}

            {:error, reason} ->
              {[], [], ChartState.query_error("Chart query", reason)}

            _ ->
              # Fallback to derived SRQL (still SRQL-only), in case the user typed a non-downsample query.
              series_field = NFQuery.downsample_series_field_from_dims(dims)
              bucket = @default_bucket
              {value_field, _scale_fun} = units_to_value_field_and_scale(units, bucket)

              {keys, points} =
                NFQuery.load_downsample_series(srql_module, base, scope,
                  bucket: bucket,
                  series_field: series_field,
                  value_field: value_field,
                  agg: "sum",
                  limit: max(@chart_limit, series_limit * 200)
                )

              {keys, points, nil}
          end

        # Apply Top-N bucketing and unit scaling (if chart_query is already scaled, this is a no-op).
        bucket = @default_bucket
        {value_field, scale_fun} = units_to_value_field_and_scale(units, bucket)
        points = NFQuery.scale_points(points, scale_fun)
        {keys, points} = NFQuery.top_n(keys, points, series_limit, limit_type)
        empty_state = load_empty_state || ChartState.for_chart_payload(graph, keys, points)

        overlays =
          if is_nil(empty_state) do
            Overlays.load_overlays(srql_module, base, scope,
              graph: graph,
              keys: keys,
              series_field: NFQuery.downsample_series_field_from_dims(dims),
              bucket: bucket,
              value_field: value_field,
              scale_fun: scale_fun,
              bidirectional: bidirectional,
              previous_period: previous_period
            )
          else
            []
          end

        socket
        |> assign(:netflow_chart_keys_json, Jason.encode!(keys))
        |> assign(:netflow_chart_points_json, Jason.encode!(points))
        |> assign(:netflow_chart_colors_json, Jason.encode!(%{}))
        |> assign(:netflow_chart_overlays_json, Jason.encode!(overlays))
        |> assign(:netflow_chart_empty_state, empty_state)
    end
  rescue
    exception ->
      socket
      |> assign(:netflow_chart_keys_json, "[]")
      |> assign(:netflow_chart_points_json, "[]")
      |> assign(:netflow_chart_colors_json, "{}")
      |> assign(:netflow_chart_overlays_json, "[]")
      |> assign(:netflow_sankey_edges_json, "[]")
      |> assign(:netflow_chart_empty_state, ChartState.query_error("Chart query", Exception.message(exception)))
  end

  def load_visualize_chart(socket, other, %{} = state), do: load_visualize_chart(socket, to_string(other || ""), state)

  def extract_srql_rows(results) when is_list(results) do
    Enum.map(results, fn
      %{"payload" => %{} = payload} -> payload
      %{} = row -> row
      _ -> %{}
    end)
  end

  def downsample_from_results(results) when is_list(results) do
    {keys, buckets} =
      Enum.reduce(results, {MapSet.new(), %{}}, fn
        %{"timestamp" => ts, "series" => series, "value" => value}, {keys, acc} ->
          with {:ok, dt} <- parse_srql_datetime(ts),
               true <- is_binary(series),
               v when is_number(v) <- to_number(value) do
            label = if series == "", do: "total", else: series
            keys = MapSet.put(keys, label)

            acc =
              Map.update(acc, dt, %{label => v}, fn m ->
                Map.update(m, label, v, &(&1 + v))
              end)

            {keys, acc}
          else
            _ -> {keys, acc}
          end

        _row, acc ->
          acc
      end)

    keys = keys |> MapSet.to_list() |> Enum.sort()

    points =
      buckets
      |> Enum.sort_by(fn {dt, _} -> DateTime.to_unix(dt, :second) end)
      |> Enum.map(fn {dt, values} ->
        base = %{"t" => DateTime.to_iso8601(dt)}

        Enum.reduce(keys, base, fn k, acc ->
          Map.put(acc, k, Map.get(values, k, 0))
        end)
      end)

    {keys, points}
  end

  def downsample_from_results(_), do: {[], []}

  def parse_srql_datetime(ts) when is_binary(ts) do
    case DateTime.from_iso8601(ts) do
      {:ok, dt, _} ->
        {:ok, dt}

      _ ->
        case NaiveDateTime.from_iso8601(ts) do
          {:ok, ndt} -> {:ok, DateTime.from_naive!(ndt, "Etc/UTC")}
          _ -> {:error, :invalid_timestamp}
        end
    end
  end

  def parse_srql_datetime(_), do: {:error, :invalid_timestamp}
end
