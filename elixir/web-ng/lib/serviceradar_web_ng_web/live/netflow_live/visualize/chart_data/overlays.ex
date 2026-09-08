defmodule ServiceRadarWebNGWeb.NetflowLive.Visualize.ChartData.Overlays do
  @moduledoc false

  import ServiceRadarWebNGWeb.NetflowLive.Visualize.Format, only: [to_float: 1]

  alias ServiceRadarWebNGWeb.NetflowLive.Visualize.TimeWindow
  alias ServiceRadarWebNGWeb.NetflowVisualize.Query, as: NFQuery

  def load_overlays(srql_module, base, scope, opts) do
    graph = Keyword.get(opts, :graph, "stacked")
    keys = opts |> Keyword.get(:keys, []) |> List.wrap()
    series_field = Keyword.get(opts, :series_field, "protocol_group")
    bucket = Keyword.get(opts, :bucket, "5m")
    value_field = Keyword.get(opts, :value_field, "bytes_total")
    scale_fun = Keyword.get(opts, :scale_fun, fn v -> v end)
    bidirectional = Keyword.get(opts, :bidirectional, false) == true
    previous_period = Keyword.get(opts, :previous_period, false) == true

    if bidirectional or previous_period do
      cond do
        graph == "stacked" ->
          load_stacked_total_overlays(srql_module, base, scope,
            bucket: bucket,
            value_field: value_field,
            scale_fun: scale_fun,
            agg: "sum",
            limit: 2000,
            bidirectional: bidirectional,
            previous_period: previous_period
          )

        graph == "stacked100" ->
          load_stacked100_composition_overlays(srql_module, base, scope,
            keys: keys,
            series_field: series_field,
            bucket: bucket,
            value_field: value_field,
            scale_fun: scale_fun,
            agg: "sum",
            limit: 2000,
            bidirectional: bidirectional,
            previous_period: previous_period
          )

        true ->
          []
      end
    else
      []
    end
  end

  def load_stacked_total_overlays(srql_module, base_query, scope, opts) do
    bucket = Keyword.get(opts, :bucket, "5m")
    value_field = Keyword.get(opts, :value_field, "bytes_total")
    agg = Keyword.get(opts, :agg, "sum")
    limit = Keyword.get(opts, :limit, 2000)
    scale_fun = Keyword.get(opts, :scale_fun, fn v -> v end)
    bidirectional = Keyword.get(opts, :bidirectional, false) == true
    previous_period = Keyword.get(opts, :previous_period, false) == true

    rev_overlay =
      if bidirectional do
        rev_query = NFQuery.flows_reverse_direction_query(base_query)

        points =
          load_total_overlay_points(srql_module, rev_query, scope,
            bucket: bucket,
            value_field: value_field,
            agg: agg,
            limit: limit,
            scale_fun: scale_fun
          )

        [%{"key" => "rev:total", "points" => points}]
      else
        []
      end

    prev_overlay =
      if previous_period do
        with {:ok, {start_dt, end_dt}} <- TimeWindow.parse_time_window_from_query(base_query),
             diff when is_integer(diff) and diff > 0 <- DateTime.diff(end_dt, start_dt, :second) do
          prev_start = DateTime.add(start_dt, -diff, :second)
          prev_end = DateTime.add(end_dt, -diff, :second)
          prev_time = "[#{DateTime.to_iso8601(prev_start)},#{DateTime.to_iso8601(prev_end)}]"
          prev_query = NFQuery.flows_replace_time(base_query, prev_time)

          points =
            srql_module
            |> load_total_overlay_points(prev_query, scope,
              bucket: bucket,
              value_field: value_field,
              agg: agg,
              limit: limit,
              scale_fun: scale_fun
            )
            |> shift_overlay_points(diff)

          [%{"key" => "prev:total", "points" => points}]
        else
          _ -> []
        end
      else
        []
      end

    rev_overlay ++ prev_overlay
  end

  def load_total_overlay_points(srql_module, query, scope, opts) do
    bucket = Keyword.get(opts, :bucket, "5m")
    value_field = Keyword.get(opts, :value_field, "bytes_total")
    agg = Keyword.get(opts, :agg, "sum")
    limit = Keyword.get(opts, :limit, 2000)
    scale_fun = Keyword.get(opts, :scale_fun, fn v -> v end)

    {_keys, points} =
      NFQuery.load_downsample_series(srql_module, query, scope,
        series_field: nil,
        bucket: bucket,
        value_field: value_field,
        agg: agg,
        limit: limit
      )

    points = NFQuery.scale_points(points, scale_fun)

    Enum.flat_map(points, fn
      %{"t" => t} = p when is_binary(t) ->
        [%{"t" => t, "v" => to_float(Map.get(p, "total", 0))}]

      _ ->
        []
    end)
  end

  def shift_overlay_points(points, seconds) when is_list(points) and is_integer(seconds) do
    Enum.map(points, fn
      %{"t" => t} = p when is_binary(t) ->
        case DateTime.from_iso8601(t) do
          {:ok, dt, _} ->
            Map.put(p, "t", dt |> DateTime.add(seconds, :second) |> DateTime.to_iso8601())

          _ ->
            p
        end

      other ->
        other
    end)
  end

  def shift_overlay_points(other, _seconds), do: other

  def load_stacked100_composition_overlays(srql_module, base_query, scope, opts) do
    keys = opts |> Keyword.get(:keys, []) |> List.wrap()
    series_field = Keyword.get(opts, :series_field, "protocol_group")
    bucket = Keyword.get(opts, :bucket, "5m")
    value_field = Keyword.get(opts, :value_field, "bytes_total")
    agg = Keyword.get(opts, :agg, "sum")
    limit = Keyword.get(opts, :limit, 2000)
    scale_fun = Keyword.get(opts, :scale_fun, fn v -> v end)
    bidirectional = Keyword.get(opts, :bidirectional, false) == true
    previous_period = Keyword.get(opts, :previous_period, false) == true

    if keys == [] do
      []
    else
      rev_overlay =
        if bidirectional do
          rev_query = NFQuery.flows_reverse_direction_query(base_query)
          rev_series = NFQuery.reverse_series_field(series_field)

          {_rev_keys, rev_points} =
            NFQuery.load_downsample_series(srql_module, rev_query, scope,
              series_field: rev_series,
              bucket: bucket,
              value_field: value_field,
              agg: agg,
              limit: limit
            )

          points =
            rev_points
            |> restrict_points_to_keys(keys)
            |> NFQuery.scale_points(scale_fun)

          [%{"type" => "rev", "points" => points}]
        else
          []
        end

      prev_overlay =
        if previous_period do
          with {:ok, {start_dt, end_dt}} <- TimeWindow.parse_time_window_from_query(base_query),
               diff when is_integer(diff) and diff > 0 <- DateTime.diff(end_dt, start_dt, :second) do
            prev_start = DateTime.add(start_dt, -diff, :second)
            prev_end = DateTime.add(end_dt, -diff, :second)
            prev_time = "[#{DateTime.to_iso8601(prev_start)},#{DateTime.to_iso8601(prev_end)}]"
            prev_query = NFQuery.flows_replace_time(base_query, prev_time)

            {_prev_keys, prev_points} =
              NFQuery.load_downsample_series(srql_module, prev_query, scope,
                series_field: series_field,
                bucket: bucket,
                value_field: value_field,
                agg: agg,
                limit: limit
              )

            points =
              prev_points
              |> restrict_points_to_keys(keys)
              |> NFQuery.scale_points(scale_fun)
              |> shift_points(diff)

            [%{"type" => "prev", "points" => points}]
          else
            _ ->
              []
          end
        else
          []
        end

      rev_overlay ++ prev_overlay
    end
  end

  def restrict_points_to_keys(points, keys) when is_list(points) and is_list(keys) do
    Enum.map(points, fn
      %{"t" => t} = point ->
        out = %{"t" => t}

        Enum.reduce(keys, out, fn k, acc ->
          Map.put(acc, k, Map.get(point, k, 0))
        end)

      other ->
        other
    end)
  end

  def shift_points(points, seconds) when is_list(points) and is_integer(seconds) do
    points =
      Enum.map(points, fn
        %{"t" => t} = point when is_binary(t) ->
          case DateTime.from_iso8601(t) do
            {:ok, dt, _} ->
              Map.put(point, "t", dt |> DateTime.add(seconds, :second) |> DateTime.to_iso8601())

            _ ->
              point
          end

        other ->
          other
      end)

    points
  end
end
