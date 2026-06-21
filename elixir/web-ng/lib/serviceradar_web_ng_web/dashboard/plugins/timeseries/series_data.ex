defmodule ServiceRadarWebNGWeb.Dashboard.Plugins.Timeseries.SeriesData do
  @moduledoc false

  alias ServiceRadarWebNGWeb.Dashboard.Plugins.Timeseries.Metrics
  alias ServiceRadarWebNGWeb.Dashboard.Plugins.Timeseries.Paths
  alias ServiceRadarWebNGWeb.Dashboard.Plugins.Timeseries.Points

  def build_series_data(series_points, spec, rate_mode, compact, max_speed) do
    series_points
    |> Enum.with_index()
    |> Enum.map(fn {{series, points}, idx} ->
      series_data_for_points(series, points, idx, spec, rate_mode, compact, max_speed)
    end)
  end

  def resolve_chart_groups(series_data, combine_all_series, chart_mode, max_speed, compact, combined_title) do
    {traffic_series, other_series} = Enum.split_with(series_data, &Metrics.traffic_series?(&1.raw_series))

    cond do
      combine_all_series && length(series_data) > 1 ->
        {[build_combined_series_data(series_data, compact, combined_title)], []}

      chart_mode == :combined and length(traffic_series) > 1 ->
        {[build_combined_traffic_data(traffic_series, max_speed, compact)], other_series}

      true ->
        {[], series_data}
    end
  end

  defp series_data_for_points(series, points, idx, spec, rate_mode, compact, max_speed) do
    effective_max = if Metrics.traffic_series?(series), do: max_speed
    {stroke, _fill} = Metrics.series_color(idx)
    display_name = Metrics.humanize_series_name(series || "series")
    unit = Metrics.unit_for_series(series, spec, rate_mode)
    points = Enum.sort_by(points, fn {dt, _} -> DateTime.to_unix(dt, :millisecond) end)
    cap = Points.points_cap(points)
    points = Points.limit_points(points, cap)
    chart_points = Points.chart_points(points, unit, compact, cap)
    scale_max = Metrics.scale_max_for_unit(unit)
    paths = Paths.chart_paths(chart_points, scale_max)
    utilization = Metrics.compute_utilization(paths.avg, effective_max)
    chart_max = Points.chart_max_from_value(paths.max, unit, scale_max)

    %{
      series: display_name,
      raw_series: series,
      paths: paths,
      stroke: stroke,
      idx: idx,
      point_data: Enum.map(chart_points, fn {dt, v} -> %{dt: Points.dt_label(dt), v: v} end),
      unit: unit,
      raw_points: points,
      x_ticks: Points.x_ticks(points, compact),
      y_ticks: Points.y_ticks(chart_max, compact, unit),
      chart_max: chart_max,
      first_dt: Points.series_first_dt(points),
      last_dt: Points.series_last_dt(points),
      max_speed: effective_max,
      utilization: utilization
    }
  end

  defp build_combined_traffic_data(traffic_series, max_speed, compact) do
    first_series = List.first(traffic_series)
    unit = Metrics.combined_unit(traffic_series)
    chart_max = Points.combined_chart_max(traffic_series, unit)
    x_ticks = first_series && Points.x_ticks(first_series.raw_points || [], compact)
    y_ticks = Points.y_ticks(chart_max, compact, unit)

    %{
      type: :combined,
      title: "Interface Traffic",
      series: traffic_series,
      max_speed: max_speed,
      unit: unit,
      chart_max: chart_max,
      x_ticks: x_ticks || [],
      y_ticks: y_ticks,
      first_dt: first_series && first_series.first_dt,
      last_dt: first_series && first_series.last_dt
    }
  end

  defp build_combined_series_data(series_data, compact, title) do
    first_series = List.first(series_data)
    unit = Metrics.combined_unit(series_data)
    chart_max = Points.combined_chart_max(series_data, unit)
    x_ticks = first_series && Points.x_ticks(first_series.raw_points || [], compact)
    y_ticks = Points.y_ticks(chart_max, compact, unit)

    %{
      type: :combined,
      title: title,
      series: series_data,
      max_speed: nil,
      unit: unit,
      chart_max: chart_max,
      x_ticks: x_ticks || [],
      y_ticks: y_ticks,
      first_dt: first_series && first_series.first_dt,
      last_dt: first_series && first_series.last_dt
    }
  end
end
