defmodule ServiceRadarWebNGWeb.Dashboard.Plugins.Timeseries do
  @moduledoc false

  @behaviour ServiceRadarWebNGWeb.Dashboard.Plugin

  use Phoenix.LiveComponent

  import ServiceRadarWebNGWeb.UIComponents, only: [ui_panel: 1]

  alias ServiceRadarWebNGWeb.SRQL.Viz

  @max_series 6
  @max_points 800
  @chart_width 800
  @chart_height 140
  @chart_pad 8
  @impl true
  def id, do: "timeseries"

  @impl true
  def title, do: "Timeseries"

  @impl true
  def supports?(%{"viz" => %{"suggestions" => suggestions}}) when is_list(suggestions) do
    Enum.any?(suggestions, fn
      %{"kind" => "timeseries"} -> true
      _ -> false
    end)
  end

  def supports?(%{"results" => results}) when is_list(results) do
    match?({:timeseries, _}, Viz.infer(results))
  end

  def supports?(_), do: false

  @impl true
  def build(%{"results" => results, "viz" => viz} = _srql_response) when is_list(results) and is_map(viz) do
    with {:ok, spec} <- parse_timeseries_spec(viz),
         {:ok, series_points, series_units} <- extract_series_points(results, spec) do
      {:ok, %{spec: Map.put(spec, :series_units, series_units), series_points: series_points}}
    end
  end

  def build(%{"results" => results} = _srql_response) when is_list(results) do
    case infer_timeseries_spec(results) do
      {:ok, spec} ->
        with {:ok, series_points, series_units} <- extract_series_points(results, spec) do
          {:ok, %{spec: Map.put(spec, :series_units, series_units), series_points: series_points}}
        end

      _ ->
        {:error, :invalid_response}
    end
  end

  def build(_), do: {:error, :invalid_response}

  defp parse_timeseries_spec(%{"suggestions" => suggestions}) when is_list(suggestions) do
    suggestion =
      Enum.find(suggestions, fn
        %{"kind" => "timeseries"} -> true
        _ -> false
      end)

    case suggestion do
      %{"x" => x, "y" => y, "series" => series} = spec
      when is_binary(x) and is_binary(y) and is_binary(series) ->
        {:ok, %{x: x, y: y, series: series, scale: Map.get(spec, "scale")}}

      %{"x" => x, "y" => y} = spec when is_binary(x) and is_binary(y) ->
        {:ok, %{x: x, y: y, series: nil, scale: Map.get(spec, "scale")}}

      _ ->
        {:error, :missing_timeseries_suggestion}
    end
  end

  defp parse_timeseries_spec(_), do: {:error, :missing_suggestions}

  defp infer_timeseries_spec(results) when is_list(results) do
    case Viz.infer(results) do
      {:timeseries, %{x: x, y: y}} -> {:ok, %{x: x, y: y, series: nil}}
      _ -> {:error, :missing_timeseries}
    end
  end

  defp extract_series_points(results, %{x: x, y: y, series: series_key}) do
    rows = Enum.filter(results, &is_map/1)

    %{points: points, units: units} =
      Enum.reduce(rows, %{points: %{}, units: %{}}, fn row, acc ->
        series =
          if is_binary(series_key) do
            row
            |> Map.get(series_key)
            |> safe_to_string()
            |> String.trim()
            |> normalize_series_label()
          else
            "series"
          end

        with {:ok, dt} <- parse_datetime(Map.get(row, x)),
             {:ok, value} <- parse_number(Map.get(row, y)) do
          acc
          |> update_in([:points], fn points ->
            Map.update(points, series, [{dt, value}], fn existing -> existing ++ [{dt, value}] end)
          end)
          |> maybe_put_series_unit(series, row_unit(row))
        else
          _ -> acc
        end
      end)

    series_points =
      points
      |> Enum.map(fn {series, series_points} ->
        sorted =
          Enum.sort_by(series_points, fn {dt, _} -> DateTime.to_unix(dt, :millisecond) end)

        {series, sorted}
      end)
      |> Enum.sort_by(fn {series, _points} -> series end)
      |> Enum.take(@max_series)

    {:ok, series_points, units}
  end

  defp maybe_put_series_unit(acc, series, unit) when is_atom(unit) do
    update_in(acc, [:units], fn units -> Map.put_new(units, series, unit) end)
  end

  defp maybe_put_series_unit(acc, _series, _unit), do: acc

  defp row_unit(row) when is_map(row) do
    Enum.find_value(
      [
        Map.get(row, "metric.unit"),
        get_in(row, ["metric", "unit"]),
        Map.get(row, "unit"),
        Map.get(row, :unit),
        Map.get(row, "metric_unit"),
        Map.get(row, :metric_unit)
      ],
      &normalize_metric_unit/1
    )
  end

  defp row_unit(_), do: nil

  defp normalize_metric_unit(value) when is_binary(value) do
    value
    |> String.trim()
    |> normalize_metric_unit_string()
  end

  defp normalize_metric_unit(unit) when unit in [:percent, :bytes, :bits_per_sec, :bytes_per_sec, :hz, :count_per_sec],
    do: unit

  defp normalize_metric_unit(_), do: nil

  defp normalize_metric_unit_string(value) do
    value
    |> String.downcase()
    |> case do
      "" -> nil
      "%" -> :percent
      "percent" -> :percent
      "by" -> :bytes
      "byte" -> :bytes
      "bytes" -> :bytes
      "b/s" -> :bits_per_sec
      "bit/s" -> :bits_per_sec
      "bits/s" -> :bits_per_sec
      "bps" -> :bits_per_sec
      "by/s" -> :bytes_per_sec
      "byte/s" -> :bytes_per_sec
      "bytes/s" -> :bytes_per_sec
      "hz" -> :hz
      "1/s" -> :count_per_sec
      "count/s" -> :count_per_sec
      "counts/s" -> :count_per_sec
      _ -> nil
    end
  end

  defp parse_number(value) when is_integer(value), do: {:ok, value * 1.0}
  defp parse_number(value) when is_float(value), do: {:ok, value}

  defp parse_number(value) when is_binary(value) do
    value = String.trim(value)

    cond do
      value == "" ->
        {:error, :empty}

      match?({_, ""}, Float.parse(value)) ->
        {v, ""} = Float.parse(value)
        {:ok, v}

      match?({_, ""}, Integer.parse(value)) ->
        {v, ""} = Integer.parse(value)
        {:ok, v * 1.0}

      true ->
        {:error, :nan}
    end
  end

  defp parse_number(_), do: {:error, :not_numeric}

  defp parse_datetime(%DateTime{} = dt), do: {:ok, dt}

  defp parse_datetime(%NaiveDateTime{} = ndt) do
    {:ok, DateTime.from_naive!(ndt, "Etc/UTC")}
  end

  defp parse_datetime(value) when is_binary(value) do
    value = String.trim(value)

    with {:error, _} <- DateTime.from_iso8601(value),
         {:ok, ndt} <- NaiveDateTime.from_iso8601(value) do
      {:ok, DateTime.from_naive!(ndt, "Etc/UTC")}
    else
      {:ok, dt, _offset} -> {:ok, dt}
      {:error, _} -> {:error, :invalid_datetime}
    end
  end

  defp parse_datetime(_), do: {:error, :not_datetime}

  defp safe_to_string(nil), do: ""
  defp safe_to_string(value) when is_binary(value), do: value
  defp safe_to_string(value) when is_integer(value), do: Integer.to_string(value)
  defp safe_to_string(value) when is_atom(value), do: Atom.to_string(value)
  defp safe_to_string(value), do: inspect(value)

  defp normalize_series_label(""), do: "overall"
  defp normalize_series_label(value), do: value

  # Chart paths with optional max_y for fixed Y-axis scaling (e.g., interface speed)
  # Always auto-scale Y-axis to actual data values for visibility
  # max_y is kept for reference/display but not used for scaling
  defp chart_paths(points, scale_bounds, scale_mode) when is_list(points) do
    values = numeric_values(points)

    case values do
      [] ->
        %{
          line: "",
          area: "",
          min: 0.0,
          max: 0.0,
          avg: 0.0,
          latest: nil,
          scale_min: 0.0,
          scale_max: 1.0,
          scale_mode: :linear
        }

      _ ->
        min_v = Enum.min(values, fn -> 0 end)
        max_v = Enum.max(values, fn -> 0 end)
        avg_v = Enum.sum(values) / length(values)
        latest = List.last(values)
        {scale_min, scale_max, effective_scale_mode} = chart_scale(values, scale_bounds, scale_mode)

        segments = chart_coordinate_segments(points, scale_min, scale_max, effective_scale_mode)
        line = path_for_segments(segments, &line_path/1)
        area = path_for_segments(segments, &area_path/1)

        %{
          line: line,
          area: area,
          min: min_v,
          max: max_v,
          avg: avg_v,
          latest: latest,
          scale_min: scale_min,
          scale_max: scale_max,
          scale_mode: effective_scale_mode
        }
    end
  end

  defp numeric_values(points) do
    points
    |> Enum.map(fn {_dt, v} -> v end)
    |> Enum.filter(&is_number/1)
  end

  defp chart_coordinate_segments(points, scale_min, scale_max, scale_mode) do
    len = length(points)

    points
    |> Enum.with_index()
    |> Enum.chunk_while(
      [],
      fn
        {{_dt, v}, idx}, acc when is_number(v) ->
          x = idx_to_x(idx, len)
          y = value_to_y(v, scale_min, scale_max, scale_mode)
          {:cont, [{x, y} | acc]}

        {_point, _idx}, [] ->
          {:cont, []}

        {_point, _idx}, acc ->
          {:cont, Enum.reverse(acc), []}
      end,
      fn
        [] -> {:cont, []}
        acc -> {:cont, Enum.reverse(acc), []}
      end
    )
    |> Enum.reject(&(&1 == []))
  end

  defp path_for_segments(segments, path_fun) do
    segments
    |> Enum.map(path_fun)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(" ")
  end

  defp chart_scale(_values, {min_v, max_v}, :log)
       when is_number(min_v) and is_number(max_v) and min_v > 0 and max_v > min_v do
    {min_v * 1.0, max_v * 1.0, :log}
  end

  defp chart_scale(_values, {min_v, max_v}, _scale_mode) when is_number(min_v) and is_number(max_v) and max_v > min_v do
    {min_v * 1.0, max_v * 1.0, :linear}
  end

  defp chart_scale(values, _scale_bounds, :log) do
    positive_values = Enum.filter(values, &(&1 > 0))

    case positive_values do
      [] ->
        {0.0, 1.0, :linear}

      values ->
        min_v = Enum.min(values)
        max_v = Enum.max(values)
        log_scale(min_v, max_v)
    end
  end

  defp chart_scale(values, _scale_bounds, _scale_mode) do
    min_v = Enum.min(values, fn -> 0.0 end)
    max_v = Enum.max(values, fn -> 0.0 end)
    linear_scale(min_v, max_v)
  end

  defp linear_scale(min_v, max_v) when min_v == max_v do
    pad = single_value_padding(min_v)
    {min_v - pad, max_v + pad, :linear}
  end

  defp linear_scale(min_v, max_v) do
    pad = (max_v - min_v) * 0.05
    {min_v - pad, max_v + pad, :linear}
  end

  defp log_scale(min_v, max_v) when min_v == max_v do
    {min_v / 10.0, max_v * 10.0, :log}
  end

  defp log_scale(min_v, max_v), do: {min_v, max_v, :log}

  defp single_value_padding(value) when value == 0.0, do: 1.0
  defp single_value_padding(value), do: max(abs(value) * 0.05, 0.001)

  defp combined_chart_scale(series_data, unit, scale_mode) when is_list(series_data) do
    values =
      series_data
      |> Enum.flat_map(fn series ->
        [
          get_in(series, [:paths, :min]),
          get_in(series, [:paths, :max])
        ]
      end)
      |> Enum.filter(&is_number/1)

    chart_scale(values, scale_bounds_for_unit(unit), scale_mode)
  end

  defp x_ticks(points, compact) when is_list(points) do
    len = length(points)

    case len do
      0 ->
        []

      1 ->
        [{@chart_pad, time_label(elem(List.first(points), 0))}]

      _ ->
        tick_count =
          cond do
            compact && len >= 4 -> 3
            len >= 6 -> 5
            true -> len
          end

        len
        |> tick_indices(tick_count)
        |> Enum.map(fn idx ->
          {dt, _v} = Enum.at(points, idx)
          {idx_to_x(idx, len), time_label(dt)}
        end)
    end
  end

  defp x_ticks(_points, _compact), do: []

  defp y_ticks(min_v, max_v, compact, unit, scale_mode) when is_number(min_v) and is_number(max_v) and max_v > min_v do
    ticks = if compact, do: 3, else: 5

    Enum.map(0..ticks, fn idx ->
      value = y_tick_value(min_v, max_v, idx, ticks, scale_mode)
      {value_to_y(value, min_v, max_v, scale_mode), format_value(value, unit)}
    end)
  end

  defp y_ticks(_min_v, _max_v, _compact, unit, _scale_mode), do: [{value_to_y(0, 0, 1, :linear), format_value(0, unit)}]

  defp y_tick_value(min_v, max_v, idx, ticks, :log) do
    log_min = log10(min_v)
    log_max = log10(max_v)
    :math.pow(10, log_min + (log_max - log_min) * idx / ticks)
  end

  defp y_tick_value(min_v, max_v, idx, ticks, _scale_mode) do
    min_v + (max_v - min_v) * idx / ticks
  end

  defp tick_indices(len, tick_count) when tick_count >= len do
    Enum.to_list(0..(len - 1))
  end

  defp tick_indices(len, tick_count) when tick_count > 1 do
    0..(tick_count - 1)
    |> Enum.map(fn idx ->
      round(idx * (len - 1) / (tick_count - 1))
    end)
    |> Enum.uniq()
  end

  defp tick_indices(_len, _tick_count), do: [0]

  defp time_label(%DateTime{} = dt), do: Calendar.strftime(dt, "%-I:%M %p")
  defp time_label(_), do: ""

  # Convert counter metrics into per-second rates by calculating deltas between points.
  defp counter_rates(series_points, max_speed) when is_list(series_points) do
    Enum.map(series_points, fn {series, points} ->
      sorted_points = Enum.sort_by(points, fn {dt, _v} -> dt end)
      series_max_speed = if traffic_series?(series), do: max_speed
      {series, counter_rate_points(sorted_points, series, series_max_speed)}
    end)
  end

  defp counter_rates(series_points, _max_speed), do: series_points

  defp counter_rate_points(points, series, max_speed) do
    {_prev, acc} =
      Enum.reduce(points, {nil, []}, fn point, state ->
        counter_rate_step(point, state, series, max_speed)
      end)

    Enum.reverse(acc)
  end

  defp counter_rate_step({dt, value}, {nil, acc}, _series, _max_speed) do
    {{dt, value}, acc}
  end

  defp counter_rate_step({dt, value}, {{prev_dt, prev_value}, acc}, series, max_speed) do
    diff = DateTime.diff(dt, prev_dt, :second)

    case counter_rate(diff, value, prev_value, series, max_speed) do
      {:ok, rate} -> {{dt, value}, [{dt, rate} | acc]}
      :gap -> {{dt, value}, [{dt, nil} | acc]}
    end
  end

  defp counter_rate(diff, _value, _prev_value, _series, _max_speed) when diff <= 0, do: :gap

  defp counter_rate(diff, value, prev_value, _series, max_speed) do
    case counter_delta(value, prev_value) do
      {:ok, delta} ->
        rate =
          delta
          |> Kernel./(diff)
          |> clamp_rate(max_speed)

        {:ok, rate}

      :gap ->
        :gap
    end
  end

  defp counter_delta(current, previous) when is_number(current) and is_number(previous) do
    if current >= previous do
      {:ok, current - previous}
    else
      :gap
    end
  end

  defp counter_delta(_, _), do: :gap

  defp clamp_rate(rate, max_speed) when is_number(rate) and is_number(max_speed) and max_speed > 0 do
    if rate > max_speed do
      max_speed
    else
      rate
    end
  end

  defp clamp_rate(rate, _max_speed), do: rate

  defp value_to_y(_v, min_v, max_v, _scale_mode) when min_v == max_v, do: round(@chart_height / 2)

  defp value_to_y(v, min_v, max_v, :log) when min_v > 0 and max_v > min_v do
    usable = @chart_height - @chart_pad * 2
    clamped = max(v, min_v)
    scaled = (log10(clamped) - log10(min_v)) / (log10(max_v) - log10(min_v))
    round(@chart_height - @chart_pad - scaled * usable)
  end

  defp value_to_y(v, min_v, max_v, _scale_mode) do
    usable = @chart_height - @chart_pad * 2
    scaled = (v - min_v) / (max_v - min_v)
    round(@chart_height - @chart_pad - scaled * usable)
  end

  defp log10(value), do: :math.log(value) / :math.log(10)

  defp line_path([]), do: ""
  defp line_path([{x, y}]), do: "M #{x},#{y}"

  defp line_path(coords) when length(coords) < 3 do
    [{x0, y0} | rest] = coords

    segments =
      Enum.map_join(rest, " ", fn {x, y} ->
        "L #{x},#{y}"
      end)

    "M #{x0},#{y0} #{segments}"
  end

  defp line_path(coords) do
    {x0, y0, segments} = monotone_segments(coords)
    "M #{x0},#{y0} #{segments}"
  end

  defp area_path([]), do: ""

  defp area_path([{x, y}]) do
    base = baseline_y()
    "M #{x},#{base} L #{x},#{y} L #{x},#{base} Z"
  end

  defp area_path(coords) when length(coords) < 3 do
    [{first_x, first_y} | rest] = coords
    {last_x, _} = List.last(coords)
    base = baseline_y()

    segments =
      Enum.map_join(rest, " ", fn {x, y} ->
        "L #{x},#{y}"
      end)

    "M #{first_x},#{base} L #{first_x},#{first_y} #{segments} L #{last_x},#{base} Z"
  end

  defp area_path(coords) do
    {x0, y0, segments} = monotone_segments(coords)
    {last_x, _} = List.last(coords)
    base = baseline_y()

    "M #{x0},#{base} L #{x0},#{y0} #{segments} L #{last_x},#{base} Z"
  end

  defp monotone_segments(coords) do
    {xs, ys} = Enum.unzip(coords)
    n = length(xs)
    deltas = deltas(xs, ys)
    slopes = slopes(xs, ys, deltas)
    segments = build_monotone_segments(xs, ys, slopes, n)
    {List.first(xs), List.first(ys), Enum.join(segments, " ")}
  end

  defp deltas(xs, ys) do
    Enum.map(0..(length(xs) - 2), fn i ->
      x0 = Enum.at(xs, i)
      x1 = Enum.at(xs, i + 1)
      y0 = Enum.at(ys, i)
      y1 = Enum.at(ys, i + 1)
      h = x1 - x0
      if h == 0, do: 0.0, else: (y1 - y0) / h
    end)
  end

  defp slopes(xs, _ys, deltas) do
    n = length(xs)

    n
    |> initial_slopes(deltas)
    |> adjust_slopes(deltas)
  end

  defp initial_slopes(n, deltas) do
    Enum.map(0..(n - 1), fn i -> slope_at(i, n, deltas) end)
  end

  defp slope_at(0, _n, deltas), do: Enum.at(deltas, 0) || 0.0
  defp slope_at(i, n, deltas) when i == n - 1, do: Enum.at(deltas, n - 2) || 0.0

  defp slope_at(i, _n, deltas) do
    d0 = Enum.at(deltas, i - 1)
    d1 = Enum.at(deltas, i)
    if d0 * d1 <= 0, do: 0.0, else: (d0 + d1) / 2
  end

  defp adjust_slopes(base, deltas) do
    Enum.reduce(0..(length(deltas) - 1), base, fn i, acc ->
      d = Enum.at(deltas, i) || 0.0
      adjust_slope_segment(acc, i, d)
    end)
  end

  defp adjust_slope_segment(acc, i, d) when d == 0.0 do
    acc
    |> List.replace_at(i, 0.0)
    |> List.replace_at(i + 1, 0.0)
  end

  defp adjust_slope_segment(acc, i, d) do
    m0 = Enum.at(acc, i) || 0.0
    m1 = Enum.at(acc, i + 1) || 0.0
    a = m0 / d
    b = m1 / d
    norm = a * a + b * b

    if norm > 9 do
      tau = 3 / :math.sqrt(norm)

      acc
      |> List.replace_at(i, tau * a * d)
      |> List.replace_at(i + 1, tau * b * d)
    else
      acc
    end
  end

  defp build_monotone_segments(xs, ys, slopes, n) do
    Enum.map(0..(n - 2), fn i ->
      x0 = Enum.at(xs, i)
      y0 = Enum.at(ys, i)
      x1 = Enum.at(xs, i + 1)
      y1 = Enum.at(ys, i + 1)
      h = x1 - x0
      m0 = Enum.at(slopes, i) || 0.0
      m1 = Enum.at(slopes, i + 1) || 0.0

      cp1x = x0 + h / 3
      cp1y = y0 + m0 * h / 3
      cp2x = x1 - h / 3
      cp2y = y1 - m1 * h / 3

      "C #{fmt(cp1x)},#{fmt(cp1y)} #{fmt(cp2x)},#{fmt(cp2y)} #{fmt(x1)},#{fmt(y1)}"
    end)
  end

  defp fmt(value) when is_number(value), do: :erlang.float_to_binary(value * 1.0, decimals: 2)

  defp baseline_y, do: @chart_height - @chart_pad

  defp chart_points(points, _unit, _compact, _cap) when is_list(points), do: points
  defp chart_points(points, _unit, _compact, _cap), do: points

  defp points_cap(points) when is_list(points) do
    width_cap = @max_points

    with [{%DateTime{} = first_dt, _} | _] <- points,
         {%DateTime{} = last_dt, _} <- List.last(points),
         {:ok, delta_secs} <- median_delta_seconds(points),
         span_secs when span_secs > 0 <- DateTime.diff(last_dt, first_dt, :second),
         expected when expected > 0 <- div(span_secs, max(delta_secs, 1)) + 1 do
      min(width_cap, max(expected, 2))
    else
      _ -> width_cap
    end
  end

  defp median_delta_seconds(points) when is_list(points) do
    deltas =
      points
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.map(fn [{dt0, _}, {dt1, _}] -> DateTime.diff(dt1, dt0, :second) end)
      |> Enum.filter(&(&1 > 0))

    case deltas do
      [] ->
        {:error, :no_deltas}

      _ ->
        sorted = Enum.sort(deltas)
        mid = div(length(sorted), 2)
        {:ok, Enum.at(sorted, mid)}
    end
  end

  defp limit_points(points, max_points) when is_list(points) and length(points) > max_points and max_points > 2 do
    indexed_points = Enum.with_index(points)
    first = List.first(indexed_points)
    last = List.last(indexed_points)
    middle = Enum.slice(indexed_points, 1, length(indexed_points) - 2)
    bucket_count = max(div(max_points - 2, 2), 1)
    bucket_size = max(ceil_div(length(middle), bucket_count), 1)

    middle_sample =
      middle
      |> Enum.chunk_every(bucket_size)
      |> Enum.flat_map(&bucket_extremes/1)

    ([first] ++ middle_sample ++ [last])
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq_by(fn {_point, idx} -> idx end)
    |> Enum.sort_by(fn {_point, idx} -> idx end)
    |> Enum.map(fn {point, _idx} -> point end)
  end

  defp limit_points(points, max_points) when is_list(points) and length(points) > max_points and max_points <= 2 do
    [List.first(points), List.last(points)]
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp limit_points(points, _max_points), do: points

  defp bucket_extremes(bucket) do
    numeric =
      Enum.filter(bucket, fn
        {{_dt, value}, _idx} -> is_number(value)
        _ -> false
      end)

    case numeric do
      [] ->
        Enum.take(bucket, 1)

      _ ->
        min_point = Enum.min_by(numeric, fn {{_dt, value}, _idx} -> value end)
        max_point = Enum.max_by(numeric, fn {{_dt, value}, _idx} -> value end)

        [min_point, max_point]
        |> Enum.uniq_by(fn {_point, idx} -> idx end)
        |> Enum.sort_by(fn {_point, idx} -> idx end)
    end
  end

  defp ceil_div(value, divisor), do: div(value + divisor - 1, divisor)

  defp idx_to_x(_idx, 0), do: @chart_pad
  defp idx_to_x(0, _len), do: @chart_pad

  defp idx_to_x(idx, len) when len > 1 do
    usable = @chart_width - @chart_pad * 2
    round(@chart_pad + idx / (len - 1) * usable)
  end

  defp series_color(index) do
    # Brand Blue palette — blues first, then distinguishable accents
    colors = [
      {"#3B82F6", "rgba(59,130,246,0.25)"},
      {"#38BDF8", "rgba(56,189,248,0.25)"},
      {"#8B5CF6", "rgba(139,92,246,0.25)"},
      {"#22C55E", "rgba(34,197,94,0.25)"},
      {"#F59E0B", "rgba(245,158,11,0.25)"},
      {"#EC4899", "rgba(236,72,153,0.25)"}
    ]

    Enum.at(colors, rem(index, length(colors)))
  end

  defp series_dasharray(index) do
    patterns = [
      nil,
      "6 4",
      "2 4",
      "8 3 2 3",
      "1 4",
      "10 4"
    ]

    Enum.at(patterns, rem(index, length(patterns)))
  end

  defp dt_label(%DateTime{} = dt), do: Calendar.strftime(dt, "%b %-d %H:%M")
  defp dt_label(_), do: ""

  defp scale_bounds_for_unit(:percent), do: {0.0, 100.0}
  defp scale_bounds_for_unit(_), do: nil

  defp scale_mode_for(assigns, spec) do
    assigns
    |> Map.get(
      :scale_mode,
      Map.get(
        assigns,
        "scale_mode",
        Map.get(assigns, :scale, Map.get(assigns, "scale", Map.get(spec || %{}, :scale)))
      )
    )
    |> normalize_scale_mode()
  end

  defp normalize_scale_mode(:log), do: :log
  defp normalize_scale_mode("log"), do: :log
  defp normalize_scale_mode(_), do: :linear

  defp unit_for_series(series, spec, rate_mode) do
    cond do
      unit = series_unit_for(spec, series) ->
        unit

      rate_mode in [:counter, :rate] ->
        if traffic_series?(series), do: :bytes_per_sec, else: :count_per_sec

      percent_field?(spec) ->
        :percent

      bytes_field?(spec) ->
        :bytes

      hz_field?(spec) ->
        :hz

      true ->
        :number
    end
  end

  defp series_unit_for(spec, series) when is_map(spec) do
    units = Map.get(spec, :series_units) || Map.get(spec, "series_units") || %{}
    series_key = safe_to_string(series)

    Map.get(units, series) ||
      Map.get(units, series_key) ||
      normalize_metric_unit(Map.get(spec, :unit) || Map.get(spec, "unit"))
  end

  defp series_unit_for(_spec, _series), do: nil

  defp percent_field?(%{y: y}) when is_binary(y), do: String.contains?(y, "percent")
  defp percent_field?(_), do: false

  defp bytes_field?(%{y: y}) when is_binary(y), do: String.contains?(y, "bytes")
  defp bytes_field?(_), do: false

  defp hz_field?(%{y: y}) when is_binary(y), do: String.contains?(y, "hz")
  defp hz_field?(_), do: false

  defp combined_unit(series_data) when is_list(series_data) do
    series_data
    |> Enum.map(&Map.get(&1, :unit))
    |> Enum.uniq()
    |> case do
      [unit] -> unit
      _ -> :number
    end
  end

  defp unit_to_string(unit) do
    case unit do
      :percent -> "percent"
      :bits_per_sec -> "bits_per_sec"
      :bytes_per_sec -> "bytes_per_sec"
      :bytes -> "bytes"
      :hz -> "hz"
      :count_per_sec -> "count_per_sec"
      _ -> "number"
    end
  end

  defp format_value(v, unit) when is_float(v) or is_integer(v) do
    value = v * 1.0

    case unit do
      :percent -> "#{Float.round(value, 1)}%"
      :bits_per_sec -> format_bits_per_sec(value)
      :bytes_per_sec -> format_bytes_per_sec(value)
      :bytes -> format_bytes(value)
      :hz -> format_hz(value)
      :count_per_sec -> format_count_per_sec(value)
      _ -> format_number(value)
    end
  end

  defp format_value(_, _), do: "—"

  defp format_number(value) do
    if abs(value) >= 1_000 do
      value |> Float.round(1) |> to_string()
    else
      value |> Float.round(2) |> to_string()
    end
  end

  defp format_bytes_per_sec(bps) when bps >= 1_000_000_000 do
    "#{Float.round(bps / 1_000_000_000, 2)} GB/s"
  end

  defp format_bytes_per_sec(bps) when bps >= 1_000_000 do
    "#{Float.round(bps / 1_000_000, 2)} MB/s"
  end

  defp format_bytes_per_sec(bps) when bps >= 1_000 do
    "#{Float.round(bps / 1_000, 2)} KB/s"
  end

  defp format_bytes_per_sec(bps) when bps >= 0 do
    "#{Float.round(bps, 1)} B/s"
  end

  defp format_bytes_per_sec(bps) do
    # Negative values (shouldn't happen with rate calc, but just in case)
    "#{Float.round(bps, 2)}"
  end

  defp format_bits_per_sec(bps) when bps >= 1_000_000_000 do
    "#{Float.round(bps / 1_000_000_000, 2)} Gbit/s"
  end

  defp format_bits_per_sec(bps) when bps >= 1_000_000 do
    "#{Float.round(bps / 1_000_000, 2)} Mbit/s"
  end

  defp format_bits_per_sec(bps) when bps >= 1_000 do
    "#{Float.round(bps / 1_000, 2)} Kbit/s"
  end

  defp format_bits_per_sec(bps) when bps >= 0 do
    "#{Float.round(bps, 1)} bit/s"
  end

  defp format_bits_per_sec(bps), do: "#{Float.round(bps, 2)}"

  defp format_bytes(bytes) when bytes >= 1_000_000_000 do
    "#{Float.round(bytes / 1_000_000_000, 2)} GB"
  end

  defp format_bytes(bytes) when bytes >= 1_000_000 do
    "#{Float.round(bytes / 1_000_000, 2)} MB"
  end

  defp format_bytes(bytes) when bytes >= 1_000 do
    "#{Float.round(bytes / 1_000, 2)} KB"
  end

  defp format_bytes(bytes) when bytes >= 0 do
    "#{Float.round(bytes, 1)} B"
  end

  defp format_bytes(bytes), do: "#{Float.round(bytes, 2)}"

  defp format_hz(value) when value >= 1_000_000_000 do
    "#{Float.round(value / 1_000_000_000, 2)} GHz"
  end

  defp format_hz(value) when value >= 1_000_000 do
    "#{Float.round(value / 1_000_000, 2)} MHz"
  end

  defp format_hz(value) when value >= 1_000 do
    "#{Float.round(value / 1_000, 2)} KHz"
  end

  defp format_hz(value) when value >= 0 do
    "#{Float.round(value, 1)} Hz"
  end

  defp format_hz(value), do: "#{Float.round(value, 2)}"

  defp format_count_per_sec(value) when value >= 1_000_000 do
    "#{Float.round(value / 1_000_000, 2)} M/s"
  end

  defp format_count_per_sec(value) when value >= 1_000 do
    "#{Float.round(value / 1_000, 2)} K/s"
  end

  defp format_count_per_sec(value) when value >= 0 do
    "#{Float.round(value, 2)} /s"
  end

  defp format_count_per_sec(value), do: "#{Float.round(value, 2)} /s"

  # Map raw SNMP metric names to human-readable labels
  defp humanize_series_name("ifInOctets"), do: "Inbound Traffic"
  defp humanize_series_name("ifOutOctets"), do: "Outbound Traffic"
  defp humanize_series_name("ifInErrors"), do: "Inbound Errors"
  defp humanize_series_name("ifOutErrors"), do: "Outbound Errors"
  defp humanize_series_name("ifInDiscards"), do: "Inbound Discards"
  defp humanize_series_name("ifOutDiscards"), do: "Outbound Discards"
  defp humanize_series_name("ifInUcastPkts"), do: "Inbound Packets"
  defp humanize_series_name("ifOutUcastPkts"), do: "Outbound Packets"
  defp humanize_series_name("ifHCInOctets"), do: "Inbound Traffic (64-bit)"
  defp humanize_series_name("ifHCOutOctets"), do: "Outbound Traffic (64-bit)"
  defp humanize_series_name(name), do: name

  # Check if a series is a traffic metric (bytes/sec) that should use interface speed scaling
  defp traffic_series?("ifInOctets"), do: true
  defp traffic_series?("ifOutOctets"), do: true
  defp traffic_series?("ifHCInOctets"), do: true
  defp traffic_series?("ifHCOutOctets"), do: true
  defp traffic_series?("Inbound"), do: true
  defp traffic_series?("Outbound"), do: true
  defp traffic_series?("Inbound (64-bit)"), do: true
  defp traffic_series?("Outbound (64-bit)"), do: true
  defp traffic_series?(_), do: false

  # Compute utilization percentage from current value and max speed
  defp compute_utilization(value, max_speed) when is_number(value) and is_number(max_speed) and max_speed > 0 do
    percentage = value / max_speed * 100
    Float.round(percentage, 1)
  end

  defp compute_utilization(_, _), do: nil

  # Badge color based on utilization percentage thresholds
  defp utilization_badge_class(pct) when pct >= 90, do: "badge-error"
  defp utilization_badge_class(pct) when pct >= 75, do: "badge-warning"
  defp utilization_badge_class(pct) when pct >= 50, do: "badge-info"
  defp utilization_badge_class(_), do: "badge-success"

  @impl true
  def update(%{panel_assigns: panel_assigns} = assigns, socket) do
    compact = Map.get(panel_assigns || %{}, :compact, false)
    # Get max speed for traffic metrics (bytes/sec) for proper Y-axis scaling
    max_speed = Map.get(panel_assigns || %{}, :max_speed_bytes_per_sec)
    # Chart mode: :single (default) or :combined (multiple series on same chart)
    chart_mode = Map.get(panel_assigns || %{}, :chart_mode, :single)
    combine_all_series = Map.get(panel_assigns || %{}, :combine_all_series, false)
    combined_title = Map.get(panel_assigns || %{}, :combined_title)
    # Rate mode: :counter (compute deltas), :rate (precomputed rates), or :none.
    rate_mode = Map.get(panel_assigns || %{}, :rate_mode, :none)
    series_points = series_points_from_assigns(assigns, panel_assigns)
    spec = fetch_panel_value(panel_assigns, :spec, Map.get(assigns, :spec))

    series_points =
      case rate_mode do
        :counter -> counter_rates(series_points, max_speed)
        _ -> series_points
      end

    socket =
      socket
      |> assign(Map.delete(assigns, :panel_assigns))
      |> assign(panel_assigns)
      |> assign(:compact, compact)
      |> assign(:series_points, series_points)
      |> assign(:spec, spec)
      |> assign(:max_speed_bytes_per_sec, max_speed)
      |> assign(:chart_mode, chart_mode)
      |> assign(:combine_all_series, combine_all_series)
      |> assign(:combined_title, combined_title)
      |> assign(:rate_mode, rate_mode)
      |> assign(:chart_width, @chart_width)
      |> assign(:chart_height, @chart_height)
      |> assign(:chart_pad, @chart_pad)

    {:ok, socket}
  end

  defp series_points_from_assigns(assigns, panel_assigns) do
    cond do
      is_map(panel_assigns) and fetch_panel_value(panel_assigns, :series_points) != nil ->
        fetch_panel_value(panel_assigns, :series_points) || []

      is_map(panel_assigns) and fetch_panel_value(panel_assigns, :series) != nil ->
        series_to_points(fetch_panel_value(panel_assigns, :series))

      true ->
        Map.get(assigns, :series_points, [])
    end
  end

  defp series_to_points(series) when is_list(series) do
    Enum.map(series, fn item ->
      name = Map.get(item, :name) || Map.get(item, "name") || "series"
      data = Map.get(item, :data) || Map.get(item, "data") || []

      points =
        data
        |> Enum.reduce([], fn point, acc ->
          time = Map.get(point, :time) || Map.get(point, "time")
          value = Map.get(point, :value) || Map.get(point, "value")

          with {:ok, dt} <- parse_datetime(time),
               {:ok, v} <- parse_number(value) do
            [{dt, v} | acc]
          else
            _ -> acc
          end
        end)
        |> Enum.reverse()

      {to_string(name), points}
    end)
  end

  defp series_to_points(_), do: []

  defp fetch_panel_value(panel_assigns, key, default \\ nil) when is_map(panel_assigns) do
    Map.get(panel_assigns, key, Map.get(panel_assigns, to_string(key), default))
  end

  @impl true
  def render(assigns) do
    compact = Map.get(assigns, :compact, false)
    series_points = assigns.series_points || []
    max_speed = Map.get(assigns, :max_speed_bytes_per_sec)
    chart_mode = Map.get(assigns, :chart_mode, :single)
    combine_all_series = Map.get(assigns, :combine_all_series, false)
    combined_title = Map.get(assigns, :combined_title, "Combined")

    series_data = build_series_data(series_points, assigns, compact, max_speed)

    {combined_charts, individual_series} =
      resolve_chart_groups(
        series_data,
        combine_all_series,
        chart_mode,
        max_speed,
        compact,
        combined_title
      )

    assigns =
      assigns
      |> assign(:compact, compact)
      |> assign(:series_count, length(series_points))
      |> assign(:series_data, individual_series)
      |> assign(:combined_charts, combined_charts)
      |> assign(:first_dt, first_dt(series_points))
      |> assign(:last_dt, last_dt(series_points))

    render_chart(assigns, compact)
  end

  defp render_chart(assigns, true), do: render_compact(assigns)
  defp render_chart(assigns, false), do: render_full(assigns)

  defp build_series_data(series_points, assigns, compact, max_speed) do
    spec = Map.get(assigns, :spec)
    rate_mode = Map.get(assigns, :rate_mode, :none)
    scale_mode = scale_mode_for(assigns, spec)

    series_points
    |> Enum.with_index()
    |> Enum.map(fn {{series, points}, idx} ->
      series_data_for_points(series, points, idx, spec, rate_mode, compact, max_speed, scale_mode)
    end)
  end

  defp series_data_for_points(series, points, idx, spec, rate_mode, compact, max_speed, scale_mode) do
    effective_max = if traffic_series?(series), do: max_speed
    {stroke, _fill} = series_color(idx)
    display_name = humanize_series_name(series || "series")
    unit = unit_for_series(series, spec, rate_mode)
    points = Enum.sort_by(points, fn {dt, _} -> DateTime.to_unix(dt, :millisecond) end)
    cap = points_cap(points)
    points = limit_points(points, cap)
    chart_points = chart_points(points, unit, compact, cap)
    paths = chart_paths(chart_points, scale_bounds_for_unit(unit), scale_mode)
    utilization = compute_utilization(paths.avg, effective_max)

    %{
      series: display_name,
      raw_series: series,
      paths: paths,
      stroke: stroke,
      dasharray: series_dasharray(idx),
      idx: idx,
      point_data: Enum.map(chart_points, fn {dt, v} -> %{dt: dt_label(dt), v: v} end),
      unit: unit,
      raw_points: points,
      chart_points: chart_points,
      x_ticks: x_ticks(points, compact),
      y_ticks: y_ticks(paths.scale_min, paths.scale_max, compact, unit, paths.scale_mode),
      chart_min: paths.scale_min,
      chart_max: paths.scale_max,
      scale_mode: paths.scale_mode,
      first_dt: series_first_dt(points),
      last_dt: series_last_dt(points),
      max_speed: effective_max,
      utilization: utilization
    }
  end

  defp resolve_chart_groups(series_data, combine_all_series, chart_mode, max_speed, compact, combined_title) do
    {traffic_series, other_series} = Enum.split_with(series_data, &traffic_series?(&1.raw_series))

    cond do
      combine_all_series && length(series_data) > 1 ->
        {[build_combined_series_data(series_data, compact, combined_title)], []}

      chart_mode == :combined and length(traffic_series) > 1 ->
        {[build_combined_traffic_data(traffic_series, max_speed, compact)], other_series}

      true ->
        {[], series_data}
    end
  end

  # Build combined traffic data for multi-series chart
  defp build_combined_traffic_data(traffic_series, max_speed, compact) do
    # Get the time range from the first series
    first_series = List.first(traffic_series)
    unit = combined_unit(traffic_series)
    scale_mode = combined_scale_mode(traffic_series)
    {chart_min, chart_max, effective_scale_mode} = combined_chart_scale(traffic_series, unit, scale_mode)
    traffic_series = rescale_series_paths(traffic_series, chart_min, chart_max, effective_scale_mode)
    x_ticks = first_series && x_ticks(first_series.raw_points || [], compact)
    y_ticks = y_ticks(chart_min, chart_max, compact, unit, effective_scale_mode)

    %{
      type: :combined,
      title: "Interface Traffic",
      series: traffic_series,
      max_speed: max_speed,
      unit: unit,
      chart_min: chart_min,
      chart_max: chart_max,
      scale_mode: effective_scale_mode,
      x_ticks: x_ticks || [],
      y_ticks: y_ticks,
      first_dt: first_series && first_series.first_dt,
      last_dt: first_series && first_series.last_dt
    }
  end

  defp build_combined_series_data(series_data, compact, title) do
    first_series = List.first(series_data)
    unit = combined_unit(series_data)
    scale_mode = combined_scale_mode(series_data)
    {chart_min, chart_max, effective_scale_mode} = combined_chart_scale(series_data, unit, scale_mode)
    series_data = rescale_series_paths(series_data, chart_min, chart_max, effective_scale_mode)
    x_ticks = first_series && x_ticks(first_series.raw_points || [], compact)
    y_ticks = y_ticks(chart_min, chart_max, compact, unit, effective_scale_mode)

    %{
      type: :combined,
      title: title,
      series: series_data,
      max_speed: nil,
      unit: unit,
      chart_min: chart_min,
      chart_max: chart_max,
      scale_mode: effective_scale_mode,
      x_ticks: x_ticks || [],
      y_ticks: y_ticks,
      first_dt: first_series && first_series.first_dt,
      last_dt: first_series && first_series.last_dt
    }
  end

  defp combined_scale_mode(series_data) do
    series_data
    |> Enum.map(&Map.get(&1, :scale_mode, :linear))
    |> Enum.find(:linear, &(&1 == :log))
  end

  defp rescale_series_paths(series_data, chart_min, chart_max, scale_mode) do
    Enum.map(series_data, fn series ->
      paths = chart_paths(Map.get(series, :chart_points, []), {chart_min, chart_max}, scale_mode)
      Map.put(series, :paths, paths)
    end)
  end

  defp render_compact(assigns) do
    ~H"""
    <div id={"panel-#{@id}"} class="p-4">
      <div class={[
        "grid gap-3",
        @series_count > 1 && "grid-cols-1 lg:grid-cols-2 xl:grid-cols-3",
        @series_count == 1 && "grid-cols-1"
      ]}>
        <%= for combined <- @combined_charts do %>
          <.combined_chart_card
            id={@id}
            data={combined}
            chart_width={@chart_width}
            chart_height={@chart_height}
            chart_pad={@chart_pad}
            compact={true}
          />
        <% end %>
        <%= for data <- @series_data do %>
          <.chart_card
            id={@id}
            data={data}
            chart_width={@chart_width}
            chart_height={@chart_height}
            chart_pad={@chart_pad}
            compact={true}
          />
        <% end %>
      </div>
    </div>
    """
  end

  defp render_full(assigns) do
    ~H"""
    <div id={"panel-#{@id}"}>
      <.ui_panel>
        <:header>
          <div class="min-w-0">
            <div class="text-sm font-semibold">{@title || "Timeseries"}</div>
          </div>
          <div class="text-xs text-base-content/50 font-mono">
            <span :if={is_struct(@first_dt, DateTime)}>{dt_label(@first_dt)}</span>
            <span class="px-1">→</span>
            <span :if={is_struct(@last_dt, DateTime)}>{dt_label(@last_dt)}</span>
          </div>
        </:header>
        
    <!-- Combined charts (multi-series on same chart) -->
        <%= for combined <- @combined_charts do %>
          <.combined_chart_card
            id={@id}
            data={combined}
            chart_width={@chart_width}
            chart_height={@chart_height}
            chart_pad={@chart_pad}
            compact={false}
          />
        <% end %>
        
    <!-- Individual series charts -->
        <div
          :if={@series_data != []}
          class={[
            "grid gap-4",
            length(@series_data) > 1 && "grid-cols-1 md:grid-cols-2",
            length(@series_data) <= 1 && "grid-cols-1"
          ]}
        >
          <%= for data <- @series_data do %>
            <.chart_card
              id={@id}
              data={data}
              chart_width={@chart_width}
              chart_height={@chart_height}
              chart_pad={@chart_pad}
              compact={false}
            />
          <% end %>
        </div>
      </.ui_panel>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :data, :map, required: true
  attr :chart_width, :integer, required: true
  attr :chart_height, :integer, required: true
  attr :chart_pad, :integer, required: true
  attr :compact, :boolean, default: false

  defp chart_card(assigns) do
    ~H"""
    <div
      id={"chart-#{@id}-#{@data.idx}"}
      class={[
        "rounded-lg border border-base-200 bg-base-100 relative group",
        @compact && "p-3",
        not @compact && "p-4"
      ]}
      phx-hook="TimeseriesChart"
      data-points={Jason.encode!(@data.point_data)}
      data-unit={unit_to_string(@data.unit)}
      data-chart-width={@chart_width}
      data-chart-pad={@chart_pad}
    >
      <div class="flex items-center justify-between gap-3 mb-2">
        <div class="flex items-center gap-2 min-w-0">
          <svg viewBox="0 0 24 8" class="h-2 w-6 shrink-0" aria-hidden="true">
            <line
              x1="1"
              x2="23"
              y1="4"
              y2="4"
              stroke={@data.stroke}
              stroke-width="3"
              stroke-linecap="round"
              stroke-dasharray={@data.dasharray}
            />
          </svg>
          <span class={["font-medium truncate", @compact && "text-xs", not @compact && "text-sm"]}>
            {@data.series}
          </span>
          <span
            :if={@data.utilization}
            class={[
              "badge badge-xs font-mono",
              utilization_badge_class(@data.utilization)
            ]}
            title={"#{@data.utilization}% of interface capacity"}
          >
            {@data.utilization}%
          </span>
        </div>
        <div class={[
          "text-base-content/60 font-mono shrink-0",
          @compact && "text-[10px]",
          not @compact && "text-xs"
        ]}>
          <span style={"color: #{@data.stroke}"}>{format_value(@data.paths.latest, @data.unit)}</span>
        </div>
      </div>

      <div class="relative">
        <svg
          viewBox={"0 0 #{@chart_width} #{@chart_height}"}
          class={["w-full", @compact && "h-24", not @compact && "h-32"]}
          preserveAspectRatio="none"
        >
          <defs>
            <linearGradient id={"series-fill-#{@id}-#{@data.idx}"} x1="0" y1="0" x2="0" y2="1">
              <stop offset="0%" stop-color={@data.stroke} stop-opacity="0.3" />
              <stop offset="100%" stop-color={@data.stroke} stop-opacity="0.05" />
            </linearGradient>
          </defs>
          
    <!-- Gridlines -->
          <g stroke="currentColor" class="text-base-content/10" stroke-dasharray="3 4">
            <%= for {y, _label} <- @data.y_ticks do %>
              <line x1={@chart_pad} x2={@chart_width - @chart_pad} y1={y} y2={y} />
            <% end %>
            <%= for {x, _label} <- @data.x_ticks do %>
              <line x1={x} x2={x} y1={@chart_pad} y2={@chart_height - @chart_pad} />
            <% end %>
          </g>
          
    <!-- Axes -->
          <g stroke="currentColor" class="text-base-content/40">
            <line x1={@chart_pad} x2={@chart_pad} y1={@chart_pad} y2={@chart_height - @chart_pad} />
            <line
              x1={@chart_pad}
              x2={@chart_width - @chart_pad}
              y1={@chart_height - @chart_pad}
              y2={@chart_height - @chart_pad}
            />
          </g>
          
    <!-- Axis ticks -->
          <g stroke="currentColor" class="text-base-content/40">
            <%= for {y, _label} <- @data.y_ticks do %>
              <line x1={@chart_pad - 3} x2={@chart_pad} y1={y} y2={y} />
            <% end %>
            <%= for {x, _label} <- @data.x_ticks do %>
              <line x1={x} x2={x} y1={@chart_height - @chart_pad} y2={@chart_height - @chart_pad + 3} />
            <% end %>
          </g>
          
    <!-- Y-axis labels -->
          <g class="text-[8px] fill-base-content/70 font-mono">
            <%= for {y, label} <- @data.y_ticks do %>
              <text x={@chart_pad - 4} y={y + 3} text-anchor="end">{label}</text>
            <% end %>
          </g>
          
    <!-- X-axis labels -->
          <g class="text-[8px] fill-base-content/70 font-mono">
            <%= for {x, label} <- @data.x_ticks do %>
              <text x={x} y={@chart_height - 2} text-anchor="middle">{label}</text>
            <% end %>
          </g>

          <path d={@data.paths.area} fill={"url(#series-fill-#{@id}-#{@data.idx})"} />
          <path
            d={@data.paths.line}
            fill="none"
            stroke={@data.stroke}
            stroke-width="2"
            stroke-linecap="round"
            stroke-linejoin="round"
            stroke-dasharray={@data.dasharray}
          />
        </svg>
        
    <!-- Hover tooltip - populated by JS -->
        <div
          class="absolute hidden pointer-events-none bg-base-300 text-base-content text-xs px-2 py-1 rounded shadow-lg z-10 font-mono whitespace-nowrap"
          data-tooltip
        >
        </div>
        <!-- Hover line -->
        <div
          class="absolute hidden pointer-events-none w-px bg-base-content/30 top-0 bottom-0"
          data-hover-line
        >
        </div>
      </div>

      <div class={[
        "flex items-center justify-between text-base-content/50 mt-1",
        @compact && "text-[10px]",
        not @compact && "text-xs"
      ]}>
        <span>avg: <span class="font-mono">{format_value(@data.paths.avg, @data.unit)}</span></span>
        <span :if={@data.max_speed} class="text-base-content/40">
          interface rate:
          <span class="font-mono">{format_value(@data.max_speed, :bytes_per_sec)}</span>
        </span>
        <span>peak: <span class="font-mono">{format_value(@data.paths.max, @data.unit)}</span></span>
      </div>
      <!-- Timeline axis -->
      <div class={[
        "flex items-center justify-between text-base-content/40 mt-1 font-mono",
        @compact && "text-[9px]",
        not @compact && "text-[10px]"
      ]}>
        <span>{@data.first_dt}</span>
        <span>{@data.last_dt}</span>
      </div>
    </div>
    """
  end

  # Combined chart card for multiple traffic series on same chart
  attr :id, :string, required: true
  attr :data, :map, required: true
  attr :chart_width, :integer, required: true
  attr :chart_height, :integer, required: true
  attr :chart_pad, :integer, required: true
  attr :compact, :boolean, default: false

  defp combined_chart_card(assigns) do
    series_tooltip_data =
      (assigns.data.series || [])
      |> Enum.map(fn series ->
        %{
          label: series.series,
          color: series.stroke,
          unit: unit_to_string(series.unit),
          points: series.point_data
        }
      end)
      |> Jason.encode!()

    assigns = assign(assigns, :series_tooltip_data, series_tooltip_data)

    ~H"""
    <div
      id={"combined-chart-#{@id}"}
      class={[
        "rounded-lg border border-base-200 bg-base-100 relative",
        @compact && "p-3",
        not @compact && "p-4"
      ]}
      phx-hook="TimeseriesCombinedChart"
      data-series={@series_tooltip_data}
      data-chart-width={@chart_width}
      data-chart-pad={@chart_pad}
    >
      <!-- Header with title and legend -->
      <div class="flex items-center justify-between gap-3 mb-2">
        <div class="flex items-center gap-2 min-w-0">
          <span class={["font-medium", @compact && "text-xs", not @compact && "text-sm"]}>
            {@data.title}
          </span>
        </div>
        <!-- Legend for each series -->
        <div class="flex items-center gap-3">
          <%= for series <- @data.series do %>
            <div class="flex items-center gap-1">
              <svg viewBox="0 0 24 8" class="h-2 w-6 shrink-0" aria-hidden="true">
                <line
                  x1="1"
                  x2="23"
                  y1="4"
                  y2="4"
                  stroke={series.stroke}
                  stroke-width="3"
                  stroke-linecap="round"
                  stroke-dasharray={series.dasharray}
                />
              </svg>
              <span class={[
                "text-base-content/70",
                @compact && "text-[10px]",
                not @compact && "text-xs"
              ]}>
                {series.series}
                <span :if={series.utilization} class="text-base-content/50">
                  ({series.utilization}%)
                </span>
              </span>
            </div>
          <% end %>
        </div>
      </div>
      
    <!-- SVG chart with multiple series -->
      <div class="relative">
        <svg
          viewBox={"0 0 #{@chart_width} #{@chart_height}"}
          class={["w-full", @compact && "h-24", not @compact && "h-40"]}
          preserveAspectRatio="none"
        >
          <!-- Gradient fills for each series -->
          <defs>
            <%= for series <- @data.series do %>
              <linearGradient id={"combined-fill-#{@id}-#{series.idx}"} x1="0" y1="0" x2="0" y2="1">
                <stop offset="0%" stop-color={series.stroke} stop-opacity="0.2" />
                <stop offset="100%" stop-color={series.stroke} stop-opacity="0.02" />
              </linearGradient>
            <% end %>
          </defs>
          
    <!-- Gridlines -->
          <g stroke="currentColor" class="text-base-content/10" stroke-dasharray="3 4">
            <%= for {y, _label} <- @data.y_ticks do %>
              <line x1={@chart_pad} x2={@chart_width - @chart_pad} y1={y} y2={y} />
            <% end %>
            <%= for {x, _label} <- @data.x_ticks do %>
              <line x1={x} x2={x} y1={@chart_pad} y2={@chart_height - @chart_pad} />
            <% end %>
          </g>
          
    <!-- Axes -->
          <g stroke="currentColor" class="text-base-content/40">
            <line x1={@chart_pad} x2={@chart_pad} y1={@chart_pad} y2={@chart_height - @chart_pad} />
            <line
              x1={@chart_pad}
              x2={@chart_width - @chart_pad}
              y1={@chart_height - @chart_pad}
              y2={@chart_height - @chart_pad}
            />
          </g>
          
    <!-- Axis ticks -->
          <g stroke="currentColor" class="text-base-content/40">
            <%= for {y, _label} <- @data.y_ticks do %>
              <line x1={@chart_pad - 3} x2={@chart_pad} y1={y} y2={y} />
            <% end %>
            <%= for {x, _label} <- @data.x_ticks do %>
              <line x1={x} x2={x} y1={@chart_height - @chart_pad} y2={@chart_height - @chart_pad + 3} />
            <% end %>
          </g>
          
    <!-- Y-axis labels -->
          <g class="text-[8px] fill-base-content/70 font-mono">
            <%= for {y, label} <- @data.y_ticks do %>
              <text x={@chart_pad - 4} y={y + 3} text-anchor="end">{label}</text>
            <% end %>
          </g>
          
    <!-- X-axis labels -->
          <g class="text-[8px] fill-base-content/70 font-mono">
            <%= for {x, label} <- @data.x_ticks do %>
              <text x={x} y={@chart_height - 2} text-anchor="middle">{label}</text>
            <% end %>
          </g>
          
    <!-- Render each series -->
          <%= for series <- @data.series do %>
            <path d={series.paths.area} fill={"url(#combined-fill-#{@id}-#{series.idx})"} />
            <path
              d={series.paths.line}
              fill="none"
              stroke={series.stroke}
              stroke-width="2"
              stroke-linecap="round"
              stroke-linejoin="round"
              stroke-dasharray={series.dasharray}
            />
          <% end %>
        </svg>
        
    <!-- Hover tooltip - populated by JS -->
        <div
          class="absolute hidden pointer-events-none bg-base-300 text-base-content text-xs px-2 py-1 rounded shadow-lg z-10 font-mono whitespace-normal"
          data-tooltip
        >
        </div>
        <!-- Hover line -->
        <div
          class="absolute hidden pointer-events-none w-px bg-base-content/30 top-0 bottom-0"
          data-hover-line
        >
        </div>
      </div>
      
    <!-- Stats footer -->
      <div class={[
        "flex items-center justify-between text-base-content/50 mt-1 gap-4",
        @compact && "text-[10px]",
        not @compact && "text-xs"
      ]}>
        <%= for series <- @data.series do %>
          <div class="flex items-center gap-1">
            <svg viewBox="0 0 18 8" class="h-2 w-5 shrink-0" aria-hidden="true">
              <line
                x1="1"
                x2="17"
                y1="4"
                y2="4"
                stroke={series.stroke}
                stroke-width="2"
                stroke-linecap="round"
                stroke-dasharray={series.dasharray}
              />
            </svg>
            <span class="font-mono">{format_value(series.paths.avg, series.unit)}</span>
          </div>
        <% end %>
        <span :if={@data.max_speed} class="text-base-content/40 ml-auto">
          interface rate:
          <span class="font-mono">{format_value(@data.max_speed, :bytes_per_sec)}</span>
        </span>
      </div>
      
    <!-- Timeline axis -->
      <div class={[
        "flex items-center justify-between text-base-content/40 mt-1 font-mono",
        @compact && "text-[9px]",
        not @compact && "text-[10px]"
      ]}>
        <span>{@data.first_dt}</span>
        <span>{@data.last_dt}</span>
      </div>
    </div>
    """
  end

  defp first_dt(series_points) when is_list(series_points) do
    Enum.find_value(series_points, fn {_series, points} ->
      case points do
        [{%DateTime{} = dt, _} | _] -> dt
        _ -> nil
      end
    end)
  end

  defp last_dt(series_points) when is_list(series_points) do
    Enum.find_value(series_points, fn {_series, points} ->
      case List.last(points) do
        {%DateTime{} = dt, _} -> dt
        _ -> nil
      end
    end)
  end

  # Get first datetime label from a list of points
  defp series_first_dt([{%DateTime{} = dt, _} | _]), do: dt_label(dt)
  defp series_first_dt(_), do: ""

  # Get last datetime label from a list of points
  defp series_last_dt(points) when is_list(points) do
    case List.last(points) do
      {%DateTime{} = dt, _} -> dt_label(dt)
      _ -> ""
    end
  end

  defp series_last_dt(_), do: ""
end
