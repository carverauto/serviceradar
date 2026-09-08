defmodule ServiceRadarWebNGWeb.Dashboard.Plugins.Timeseries.SeriesData do
  @moduledoc false

  alias ServiceRadarWebNGWeb.Dashboard.Plugins.Timeseries.Metrics
  alias ServiceRadarWebNGWeb.Dashboard.Plugins.Timeseries.Paths
  alias ServiceRadarWebNGWeb.Dashboard.Plugins.Timeseries.Points

  def build_series_data(series_points, spec, rate_mode, compact, max_speed, annotations \\ [], y_scale \\ :linear) do
    build_series_data(series_points, spec, rate_mode, compact, max_speed, annotations, [], y_scale)
  end

  def build_series_data(series_points, spec, rate_mode, compact, max_speed, annotations, reference_lines, y_scale) do
    opts = %{
      annotations: annotations,
      chart_overlays: [],
      compact: compact,
      max_speed: max_speed,
      rate_mode: rate_mode,
      reference_lines: reference_lines,
      spec: spec,
      y_scale: y_scale
    }

    build_series_data_from_options(series_points, opts)
  end

  def build_series_data(series_points, opts) when is_list(opts) do
    opts = %{
      annotations: Keyword.get(opts, :annotations, []),
      chart_overlays: Keyword.get(opts, :chart_overlays, []),
      compact: Keyword.get(opts, :compact, false),
      max_speed: Keyword.get(opts, :max_speed),
      rate_mode: Keyword.get(opts, :rate_mode, :none),
      reference_lines: Keyword.get(opts, :reference_lines, []),
      spec: Keyword.get(opts, :spec),
      y_scale: Keyword.get(opts, :y_scale, :linear)
    }

    build_series_data_from_options(series_points, opts)
  end

  defp build_series_data_from_options(series_points, opts) when is_map(opts) do
    series_points
    |> Enum.with_index()
    |> Enum.map(fn {{series, points}, idx} ->
      series_data_for_points(series, points, idx, opts)
    end)
  end

  def resolve_chart_groups(
        series_data,
        combine_all_series,
        chart_mode,
        max_speed,
        compact,
        combined_title,
        y_scale \\ :linear
      ) do
    {traffic_series, other_series} = Enum.split_with(series_data, &Metrics.traffic_series?(&1.raw_series))

    cond do
      combine_all_series && length(series_data) > 1 ->
        resolve_combined_series_data(series_data, compact, combined_title, y_scale)

      chart_mode == :combined and length(traffic_series) > 1 ->
        {[build_combined_traffic_data(traffic_series, max_speed, compact, y_scale)], other_series}

      true ->
        {[], series_data}
    end
  end

  defp series_data_for_points(series, points, idx, opts) do
    %{
      annotations: annotations,
      chart_overlays: chart_overlays,
      compact: compact,
      max_speed: max_speed,
      rate_mode: rate_mode,
      reference_lines: reference_lines,
      spec: spec,
      y_scale: y_scale
    } = opts

    effective_max = if Metrics.traffic_series?(series), do: max_speed
    {stroke, _fill} = Metrics.series_color(idx)
    display_name = Metrics.humanize_series_name(series || "series")
    unit = Metrics.unit_for_series(series, spec, rate_mode)
    points = Enum.sort_by(points, fn {dt, _} -> DateTime.to_unix(dt, :millisecond) end)
    raw_stats = Paths.stats(points)
    cap = Points.points_cap(points)
    points = Points.limit_points(points, cap)
    chart_points = Points.chart_points(points, unit, compact, cap)
    reference_values = reference_line_values(reference_lines, series, display_name)
    y_domain = Points.y_domain(chart_points ++ reference_points(reference_values), unit, y_scale)
    y_ticks = Points.y_ticks(y_domain, compact, unit)
    chart_left_pad = Paths.chart_left_pad(y_ticks)
    geometry = %{chart_left_pad: chart_left_pad}
    paths = chart_points |> Paths.chart_paths(y_domain, geometry) |> Map.merge(raw_stats)
    utilization = Metrics.compute_utilization(paths.avg, effective_max)

    %{
      series: display_name,
      raw_series: series,
      paths: paths,
      stroke: stroke,
      idx: idx,
      point_data: point_data(chart_points, geometry),
      unit: unit,
      raw_points: points,
      y_domain: y_domain,
      x_ticks: Points.x_ticks(points, compact, geometry),
      y_ticks: y_ticks,
      chart_left_pad: chart_left_pad,
      chart_min: y_domain.min,
      chart_max: y_domain.max,
      y_scale: y_domain.scale,
      annotations: annotation_markers(annotations, points, series, display_name, geometry),
      overlays: overlay_markers(chart_overlays, points, series, display_name, y_domain, unit, geometry),
      reference_lines: reference_line_markers(reference_lines, y_domain, series, display_name, unit),
      raw_reference_lines: reference_lines,
      raw_chart_overlays: chart_overlays,
      first_dt: Points.series_first_dt(points),
      last_dt: Points.series_last_dt(points),
      max_speed: effective_max,
      utilization: utilization
    }
  end

  defp build_combined_traffic_data(traffic_series, max_speed, compact, y_scale) do
    first_series = List.first(traffic_series)
    unit = Metrics.combined_unit(traffic_series)
    y_domain = combined_y_domain(traffic_series, unit, y_scale)
    y_ticks = Points.y_ticks(y_domain, compact, unit)
    chart_left_pad = Paths.chart_left_pad(y_ticks)
    geometry = %{chart_left_pad: chart_left_pad}
    traffic_series = apply_shared_domain(traffic_series, y_domain, unit, compact, geometry)
    x_ticks = first_series && Points.x_ticks(first_series.raw_points || [], compact, geometry)

    %{
      type: :combined,
      title: "Interface Traffic",
      series: traffic_series,
      max_speed: max_speed,
      unit: unit,
      y_domain: y_domain,
      chart_min: y_domain.min,
      chart_max: y_domain.max,
      y_scale: y_domain.scale,
      chart_left_pad: chart_left_pad,
      annotations: combined_annotation_markers(traffic_series),
      overlays: combined_overlay_markers(traffic_series),
      reference_lines: combined_reference_line_markers(traffic_series, y_domain, unit),
      x_ticks: x_ticks || [],
      y_ticks: y_ticks,
      first_dt: first_series && first_series.first_dt,
      last_dt: first_series && first_series.last_dt
    }
  end

  defp build_combined_series_data(series_data, compact, title, y_scale) do
    first_series = List.first(series_data)
    unit = Metrics.combined_unit(series_data)
    y_domain = combined_y_domain(series_data, unit, y_scale)
    y_ticks = Points.y_ticks(y_domain, compact, unit)
    chart_left_pad = Paths.chart_left_pad(y_ticks)
    geometry = %{chart_left_pad: chart_left_pad}
    series_data = apply_shared_domain(series_data, y_domain, unit, compact, geometry)
    x_ticks = first_series && Points.x_ticks(first_series.raw_points || [], compact, geometry)

    %{
      type: :combined,
      title: title,
      series: series_data,
      max_speed: nil,
      unit: unit,
      y_domain: y_domain,
      chart_min: y_domain.min,
      chart_max: y_domain.max,
      y_scale: y_domain.scale,
      chart_left_pad: chart_left_pad,
      annotations: combined_annotation_markers(series_data),
      overlays: combined_overlay_markers(series_data),
      reference_lines: combined_reference_line_markers(series_data, y_domain, unit),
      x_ticks: x_ticks || [],
      y_ticks: y_ticks,
      first_dt: first_series && first_series.first_dt,
      last_dt: first_series && first_series.last_dt
    }
  end

  defp resolve_combined_series_data(series_data, compact, title, y_scale) do
    series_data
    |> Enum.group_by(& &1.unit)
    |> Enum.sort_by(fn {unit, _series} -> Metrics.unit_to_string(unit) end)
    |> Enum.reduce({[], []}, fn {_unit, unit_series}, {combined, individual} ->
      case unit_series do
        [_single] ->
          {combined, individual ++ unit_series}

        unit_series ->
          {[build_combined_series_data(unit_series, compact, title, y_scale) | combined], individual}
      end
    end)
    |> then(fn {combined, individual} -> {Enum.reverse(combined), individual} end)
  end

  defp combined_annotation_markers(series_data) when is_list(series_data) do
    series_data
    |> Enum.flat_map(&Map.get(&1, :annotations, []))
    |> Enum.uniq_by(fn marker -> {marker.x, marker.label, marker.severity} end)
    |> Enum.sort_by(& &1.x)
  end

  defp combined_overlay_markers(series_data) when is_list(series_data) do
    series_data
    |> Enum.flat_map(&Map.get(&1, :overlays, []))
    |> Enum.uniq_by(fn marker ->
      {Map.get(marker, :kind), Map.get(marker, :x), Map.get(marker, :window_x1), Map.get(marker, :label)}
    end)
    |> Enum.sort_by(fn marker -> Map.get(marker, :x) || Map.get(marker, :window_x1) || 0 end)
  end

  defp combined_y_domain(series_data, unit, y_scale) when is_list(series_data) do
    series_data
    |> Enum.flat_map(fn series ->
      reference_values =
        series
        |> Map.get(:raw_reference_lines, [])
        |> reference_line_values(Map.get(series, :raw_series), Map.get(series, :series))

      Map.get(series, :raw_points, []) ++ reference_points(reference_values)
    end)
    |> Points.y_domain(unit, y_scale)
  end

  defp apply_shared_domain(series_data, y_domain, unit, compact, geometry) do
    Enum.map(series_data, fn series ->
      points = Map.get(series, :raw_points, [])
      chart_points = Points.chart_points(points, unit, compact, length(points))
      raw_stats = Paths.stats(points)
      paths = chart_points |> Paths.chart_paths(y_domain, geometry) |> Map.merge(raw_stats)

      %{
        series
        | paths: paths,
          point_data: point_data(chart_points, geometry),
          y_domain: y_domain,
          y_ticks: Points.y_ticks(y_domain, compact, series.unit),
          chart_left_pad: geometry.chart_left_pad,
          chart_min: y_domain.min,
          chart_max: y_domain.max,
          y_scale: y_domain.scale,
          reference_lines:
            reference_line_markers(
              Map.get(series, :raw_reference_lines, []),
              y_domain,
              series.raw_series,
              series.series,
              series.unit
            ),
          overlays:
            overlay_markers(
              Map.get(series, :raw_chart_overlays, []),
              points,
              series.raw_series,
              series.series,
              y_domain,
              unit,
              geometry
            )
      }
    end)
  end

  defp point_data(points, geometry) when is_list(points) do
    Enum.map(points, fn {dt, v} ->
      %{dt: canonical_time(dt), v: v, x: Paths.datetime_to_x(dt, points, geometry)}
    end)
  end

  defp annotation_markers(annotations, points, raw_series, display_name, geometry)
       when is_list(annotations) and is_list(points) do
    annotations
    |> Enum.filter(&annotation_applies_to_series?(&1, raw_series, display_name))
    |> Enum.map(&annotation_marker(&1, points, geometry))
    |> Enum.reject(&is_nil/1)
  end

  defp annotation_markers(_annotations, _points, _raw_series, _display_name, _geometry), do: []

  defp annotation_applies_to_series?(%{series: nil}, _raw_series, _display_name), do: true

  defp annotation_applies_to_series?(%{series: series}, raw_series, display_name) do
    raw = raw_series |> safe_to_string() |> String.trim()
    humanized = Metrics.humanize_series_name(raw_series || "series")

    series in [raw, display_name, humanized]
  end

  defp annotation_marker(%{dt: dt, label: label, severity: severity} = annotation, points, geometry) do
    case annotation_position(dt, points, geometry) do
      nil ->
        nil

      {x, window_position} ->
        window = annotation_window(annotation, points, geometry)

        %{
          x: x,
          window_x1: Map.get(window, :x1),
          window_x2: Map.get(window, :x2),
          window_position: window_position,
          label: label,
          severity: severity,
          color: annotation_color(severity),
          title: annotation_title(label, dt, window_position),
          time_iso: canonical_time(dt)
        }
    end
  end

  defp annotation_window(%{start_dt: %DateTime{} = start_dt, end_dt: %DateTime{} = end_dt}, points, geometry) do
    with x1 when is_number(x1) <- annotation_x(start_dt, points, geometry),
         x2 when is_number(x2) <- annotation_x(end_dt, points, geometry),
         true <- x2 > x1 do
      %{x1: x1, x2: x2}
    else
      _ -> %{}
    end
  end

  defp annotation_window(%{start_dt: %DateTime{} = start_dt, dt: %DateTime{} = marker_dt}, points, geometry) do
    with x1 when is_number(x1) <- annotation_x(start_dt, points, geometry),
         x2 when is_number(x2) <- annotation_x(marker_dt, points, geometry),
         true <- x2 > x1 do
      %{x1: x1, x2: x2}
    else
      _ -> %{}
    end
  end

  defp annotation_window(_annotation, _points, _geometry), do: %{}

  defp annotation_x(dt, points, geometry), do: Paths.datetime_to_x(dt, points, geometry)

  defp annotation_position(_dt, [], _geometry), do: nil

  defp annotation_position(%DateTime{} = dt, points, geometry) when is_list(points) do
    times =
      points
      |> Enum.map(fn
        {%DateTime{} = point_dt, _value} -> DateTime.to_unix(point_dt, :millisecond)
        _point -> nil
      end)
      |> Enum.reject(&is_nil/1)

    target = DateTime.to_unix(dt, :millisecond)

    case times do
      [] ->
        nil

      [only] when target == only ->
        {chart_left_pad(geometry), :in_window}

      [only] when target < only ->
        {chart_left_pad(geometry), :before_window}

      [_only] ->
        {chart_right_edge(geometry), :after_window}

      _ ->
        first = List.first(times)
        last = List.last(times)

        cond do
          target < first -> {chart_left_pad(geometry), :before_window}
          target > last -> {chart_right_edge(geometry), :after_window}
          true -> {Paths.datetime_to_x(dt, points, geometry), :in_window}
        end
    end
  end

  defp annotation_position(_dt, _points, _geometry), do: nil

  defp annotation_title(label, dt, :before_window), do: "#{label} - #{canonical_time(dt)} (before chart window)"

  defp annotation_title(label, dt, :after_window), do: "#{label} - #{canonical_time(dt)} (after chart window)"

  defp annotation_title(label, dt, _position), do: "#{label} - #{canonical_time(dt)}"

  defp chart_left_pad(%{chart_left_pad: left}) when is_number(left), do: left
  defp chart_left_pad(_geometry), do: Paths.chart_left_pad()

  defp chart_right_edge(%{chart_right_pad: right}) when is_number(right), do: Paths.chart_width() - right
  defp chart_right_edge(_geometry), do: Paths.chart_width() - Paths.chart_right_pad()

  defp annotation_color(:critical), do: "#EF4444"
  defp annotation_color(:high), do: "#F97316"
  defp annotation_color(:warning), do: "#EAB308"
  defp annotation_color(_severity), do: "#0EA5E9"

  defp overlay_markers(overlays, points, raw_series, display_name, y_domain, unit, geometry)
       when is_list(overlays) and is_list(points) do
    overlays
    |> Enum.filter(&overlay_applies_to_series?(&1, raw_series, display_name))
    |> Enum.map(&overlay_marker(&1, points, y_domain, unit, geometry))
    |> Enum.reject(&is_nil/1)
  end

  defp overlay_markers(_overlays, _points, _raw_series, _display_name, _y_domain, _unit, _geometry), do: []

  defp overlay_applies_to_series?(%{series: nil}, _raw_series, _display_name), do: true

  defp overlay_applies_to_series?(%{series: series}, raw_series, display_name) do
    raw = raw_series |> safe_to_string() |> String.trim()
    humanized = Metrics.humanize_series_name(raw_series || "series")

    series in [raw, display_name, humanized]
  end

  defp overlay_marker(%{kind: :anomaly} = overlay, points, y_domain, unit, geometry) do
    x = annotation_x(overlay.dt, points, geometry)
    window = overlay_window(overlay, points, geometry)
    y = overlay_value_y(Map.get(overlay, :value), y_domain)

    if x || window || y do
      %{
        kind: :anomaly,
        x: x,
        window_x1: window && elem(window, 0),
        window_x2: window && elem(window, 1),
        value_y: y,
        value_label: overlay_value_label(Map.get(overlay, :value), unit),
        label: overlay.label,
        severity: overlay.severity,
        selected: Map.get(overlay, :selected, false),
        color: annotation_color(overlay.severity),
        title: anomaly_overlay_title(overlay, unit),
        time_iso: canonical_time(overlay.dt)
      }
    end
  end

  defp overlay_marker(%{kind: :capacity} = overlay, points, y_domain, unit, geometry) do
    x = annotation_x(overlay.dt, points, geometry)
    runway = capacity_runway(overlay, points, y_domain, geometry)
    confidence = if x || runway, do: confidence_band(overlay, y_domain)

    if x || runway || confidence do
      %{
        kind: :capacity,
        x: x,
        runway: runway,
        confidence: confidence,
        label: overlay.label,
        severity: overlay.severity,
        color: reference_line_color(overlay.severity),
        title: capacity_overlay_title(overlay, unit),
        time_iso: canonical_time(overlay.dt)
      }
    end
  end

  defp overlay_marker(_overlay, _points, _y_domain, _unit, _geometry), do: nil

  defp overlay_window(
         %{window_started_at: %DateTime{} = started_at, window_ended_at: %DateTime{} = ended_at},
         points,
         geometry
       ) do
    with x1 when is_number(x1) <- annotation_x(started_at, points, geometry),
         x2 when is_number(x2) <- annotation_x(ended_at, points, geometry),
         true <- x2 >= x1 do
      {x1, x2}
    else
      _ -> nil
    end
  end

  defp overlay_window(_overlay, _points, _geometry), do: nil

  defp overlay_value_y(value, y_domain) when is_number(value) do
    if reference_line_visible?(value, y_domain) do
      Paths.value_to_y(value, y_domain.min, y_domain.max, y_domain.scale)
    end
  end

  defp overlay_value_y(_value, _y_domain), do: nil

  defp capacity_runway(
         %{forecasted_at: %DateTime{} = forecasted_at, dt: %DateTime{} = dt} = overlay,
         points,
         y_domain,
         geometry
       ) do
    with x1 when is_number(x1) <- annotation_x(forecasted_at, points, geometry),
         x2 when is_number(x2) <- annotation_x(dt, points, geometry),
         y1 when is_number(y1) <- overlay_value_y(Map.get(overlay, :current_value), y_domain),
         y2 when is_number(y2) <- overlay_value_y(Map.get(overlay, :projected_value), y_domain) do
      %{x1: x1, y1: y1, x2: x2, y2: y2}
    else
      _ -> nil
    end
  end

  defp capacity_runway(_overlay, _points, _y_domain, _geometry), do: nil

  defp confidence_band(%{lower_bound: lower, upper_bound: upper}, y_domain) when is_number(lower) and is_number(upper) do
    with true <- lower <= upper,
         y_upper when is_number(y_upper) <- overlay_value_y(upper, y_domain),
         y_lower when is_number(y_lower) <- overlay_value_y(lower, y_domain) do
      %{y: y_upper, height: max(y_lower - y_upper, 1)}
    else
      _ -> nil
    end
  end

  defp confidence_band(_overlay, _y_domain), do: nil

  defp anomaly_overlay_title(overlay, unit) do
    detail =
      [
        overlay.label,
        overlay_value_label(Map.get(overlay, :value), unit),
        score_label(Map.get(overlay, :score)),
        Map.get(overlay, :disposition),
        Map.get(overlay, :reason),
        canonical_time(overlay.dt)
      ]
      |> Enum.reject(&blank?/1)
      |> Enum.join(" - ")

    if detail == "", do: "Anomaly finding", else: detail
  end

  defp capacity_overlay_title(overlay, unit) do
    [
      overlay.label,
      "projected #{overlay_value_label(Map.get(overlay, :projected_value), unit)}",
      "threshold #{overlay_value_label(Map.get(overlay, :threshold_value), unit)}",
      canonical_time(overlay.dt)
    ]
    |> Enum.reject(&blank?/1)
    |> Enum.join(" - ")
  end

  defp overlay_value_label(value, unit) when is_number(value), do: Metrics.format_value(value, unit)
  defp overlay_value_label(_value, _unit), do: nil

  defp score_label(score) when is_number(score), do: "score #{Float.round(score * 1.0, 2)}"
  defp score_label(_score), do: nil

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(_), do: false

  defp canonical_time(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  defp canonical_time(_value), do: ""

  defp reference_points(values) when is_list(values), do: Enum.map(values, &{nil, &1})

  defp reference_line_values(reference_lines, raw_series, display_name) when is_list(reference_lines) do
    reference_lines
    |> Enum.filter(&reference_line_applies_to_series?(&1, raw_series, display_name))
    |> Enum.map(&Map.get(&1, :value))
    |> Enum.filter(&is_number/1)
  end

  defp reference_line_values(_reference_lines, _raw_series, _display_name), do: []

  defp reference_line_markers(reference_lines, y_domain, raw_series, display_name, unit)
       when is_list(reference_lines) and is_map(y_domain) do
    reference_lines
    |> Enum.filter(&reference_line_applies_to_series?(&1, raw_series, display_name))
    |> Enum.map(&reference_line_marker(&1, y_domain, unit))
    |> Enum.reject(&is_nil/1)
  end

  defp reference_line_markers(_reference_lines, _y_domain, _raw_series, _display_name, _unit), do: []

  defp combined_reference_line_markers(series_data, y_domain, _unit) when is_list(series_data) do
    series_data
    |> Enum.flat_map(&Map.get(&1, :reference_lines, []))
    |> Enum.map(fn marker ->
      %{marker | y: Paths.value_to_y(marker.value, y_domain.min, y_domain.max, y_domain.scale)}
    end)
    |> Enum.reject(fn marker -> is_nil(marker.y) end)
    |> Enum.uniq_by(fn marker -> {marker.value, marker.label, marker.series} end)
    |> Enum.sort_by(& &1.y)
  end

  defp reference_line_applies_to_series?(%{series: nil}, _raw_series, _display_name), do: true

  defp reference_line_applies_to_series?(%{series: series}, raw_series, display_name) do
    raw = raw_series |> safe_to_string() |> String.trim()
    humanized = Metrics.humanize_series_name(raw_series || "series")

    series in [raw, display_name, humanized]
  end

  defp reference_line_marker(%{value: value, label: label, severity: severity, series: series}, y_domain, unit)
       when is_number(value) do
    with true <- reference_line_visible?(value, y_domain),
         y when is_number(y) <- Paths.value_to_y(value, y_domain.min, y_domain.max, y_domain.scale) do
      %{
        value: value,
        y: y,
        label: label,
        severity: severity,
        series: series,
        color: reference_line_color(severity),
        title: "#{label} - #{Metrics.format_value(value, unit)}"
      }
    else
      _ -> nil
    end
  end

  defp reference_line_marker(_reference_line, _y_domain, _unit), do: nil

  defp reference_line_visible?(value, %{scale: :log}) when value <= 0, do: false
  defp reference_line_visible?(value, %{min: min_v, max: max_v}), do: value >= min_v and value <= max_v

  defp reference_line_color(:critical), do: "#EF4444"
  defp reference_line_color(:high), do: "#F97316"
  defp reference_line_color(:warning), do: "#EAB308"
  defp reference_line_color(_severity), do: "#0EA5E9"

  defp safe_to_string(nil), do: ""
  defp safe_to_string(value) when is_binary(value), do: value
  defp safe_to_string(value) when is_integer(value), do: Integer.to_string(value)
  defp safe_to_string(value) when is_atom(value), do: Atom.to_string(value)
  defp safe_to_string(value), do: inspect(value)
end
