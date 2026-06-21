defmodule ServiceRadarWebNGWeb.Dashboard.Plugins.Timeseries.SeriesData do
  @moduledoc false

  alias ServiceRadarWebNGWeb.Dashboard.Plugins.Timeseries.Metrics
  alias ServiceRadarWebNGWeb.Dashboard.Plugins.Timeseries.Paths
  alias ServiceRadarWebNGWeb.Dashboard.Plugins.Timeseries.Points

  def build_series_data(series_points, spec, rate_mode, compact, max_speed, annotations \\ []) do
    series_points
    |> Enum.with_index()
    |> Enum.map(fn {{series, points}, idx} ->
      series_data_for_points(series, points, idx, spec, rate_mode, compact, max_speed, annotations)
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

  defp series_data_for_points(series, points, idx, spec, rate_mode, compact, max_speed, annotations) do
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
      annotations: annotation_markers(annotations, points, series, display_name),
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
      annotations: combined_annotation_markers(traffic_series),
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
      annotations: combined_annotation_markers(series_data),
      x_ticks: x_ticks || [],
      y_ticks: y_ticks,
      first_dt: first_series && first_series.first_dt,
      last_dt: first_series && first_series.last_dt
    }
  end

  defp combined_annotation_markers(series_data) when is_list(series_data) do
    series_data
    |> Enum.flat_map(&Map.get(&1, :annotations, []))
    |> Enum.uniq_by(fn marker -> {marker.x, marker.label, marker.severity} end)
    |> Enum.sort_by(& &1.x)
  end

  defp combined_annotation_markers(_series_data), do: []

  defp annotation_markers(annotations, points, raw_series, display_name) when is_list(annotations) and is_list(points) do
    annotations
    |> Enum.filter(&annotation_applies_to_series?(&1, raw_series, display_name))
    |> Enum.map(&annotation_marker(&1, points))
    |> Enum.reject(&is_nil/1)
  end

  defp annotation_markers(_annotations, _points, _raw_series, _display_name), do: []

  defp annotation_applies_to_series?(%{series: nil}, _raw_series, _display_name), do: true

  defp annotation_applies_to_series?(%{series: series}, raw_series, display_name) do
    raw = raw_series |> safe_to_string() |> String.trim()
    humanized = Metrics.humanize_series_name(raw_series || "series")

    series in [raw, display_name, humanized]
  end

  defp annotation_marker(%{dt: dt, label: label, severity: severity}, points) do
    case annotation_x(dt, points) do
      nil ->
        nil

      x ->
        %{
          x: x,
          label: label,
          severity: severity,
          color: annotation_color(severity),
          title: "#{label} - #{Points.dt_label(dt)}"
        }
    end
  end

  defp annotation_x(_dt, []), do: nil

  defp annotation_x(dt, [{point_dt, _value}]) do
    if DateTime.compare(dt, point_dt) == :eq, do: Paths.idx_to_x(0, 1)
  end

  defp annotation_x(dt, points) when is_list(points) do
    times = Enum.map(points, fn {point_dt, _value} -> DateTime.to_unix(point_dt, :millisecond) end)
    target = DateTime.to_unix(dt, :millisecond)
    first = List.first(times)
    last = List.last(times)

    cond do
      target < first or target > last ->
        nil

      target == first ->
        Paths.idx_to_x(0, length(points))

      target == last ->
        Paths.idx_to_x(length(points) - 1, length(points))

      true ->
        annotation_x_between(target, times)
    end
  end

  defp annotation_x_between(target, times) do
    len = length(times)

    times
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.with_index()
    |> Enum.find_value(fn {[left, right], idx} ->
      if target >= left and target <= right do
        left_x = Paths.idx_to_x(idx, len)
        right_x = Paths.idx_to_x(idx + 1, len)

        if right == left do
          left_x
        else
          Float.round(left_x + (target - left) / (right - left) * (right_x - left_x), 2)
        end
      end
    end)
  end

  defp annotation_color(:critical), do: "#EF4444"
  defp annotation_color(:high), do: "#F97316"
  defp annotation_color(:warning), do: "#EAB308"
  defp annotation_color(_severity), do: "#0EA5E9"

  defp safe_to_string(nil), do: ""
  defp safe_to_string(value) when is_binary(value), do: value
  defp safe_to_string(value) when is_integer(value), do: Integer.to_string(value)
  defp safe_to_string(value) when is_atom(value), do: Atom.to_string(value)
  defp safe_to_string(value), do: inspect(value)
end
