defmodule ServiceRadarWebNGWeb.Dashboard.Plugins.Timeseries do
  @moduledoc false

  use Phoenix.LiveComponent

  @behaviour ServiceRadarWebNGWeb.Dashboard.Plugin

  import ServiceRadarWebNGWeb.UIComponents, only: [ui_panel: 1]
  alias ServiceRadarWebNGWeb.SRQL.Viz

  @max_series 6
  @max_points 800
  @chart_width 800
  @chart_height 140
  @chart_pad 8
  @counter_max_32 4_294_967_295.0
  @counter_max_64 18_446_744_073_709_551_615.0

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
  def build(%{"results" => results, "viz" => viz} = _srql_response)
      when is_list(results) and is_map(viz) do
    with {:ok, spec} <- parse_timeseries_spec(viz),
         {:ok, series_points} <- extract_series_points(results, spec) do
      {:ok, %{spec: spec, series_points: series_points}}
    end
  end

  def build(%{"results" => results} = _srql_response) when is_list(results) do
    case infer_timeseries_spec(results) do
      {:ok, spec} ->
        with {:ok, series_points} <- extract_series_points(results, spec) do
          {:ok, %{spec: spec, series_points: series_points}}
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
      %{"x" => x, "y" => y, "series" => series}
      when is_binary(x) and is_binary(y) and is_binary(series) ->
        {:ok, %{x: x, y: y, series: series}}

      %{"x" => x, "y" => y} when is_binary(x) and is_binary(y) ->
        {:ok, %{x: x, y: y, series: nil}}

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
    rows =
      results
      |> Enum.filter(&is_map/1)

    points =
      Enum.reduce(rows, %{}, fn row, acc ->
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
          Map.update(acc, series, [{dt, value}], fn existing -> existing ++ [{dt, value}] end)
        else
          _ -> acc
        end
      end)

    series_points =
      points
      |> Enum.map(fn {series, series_points} ->
        sorted =
          series_points
          |> Enum.sort_by(fn {dt, _} -> DateTime.to_unix(dt, :millisecond) end)

        {series, sorted}
      end)
      |> Enum.sort_by(fn {series, _points} -> series end)
      |> Enum.take(@max_series)

    {:ok, series_points}
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
  defp normalize_series_label(nil), do: "overall"
  defp normalize_series_label(value), do: value

  # Chart paths with optional max_y for fixed Y-axis scaling (e.g., interface speed)
  # Always auto-scale Y-axis to actual data values for visibility
  # max_y is kept for reference/display but not used for scaling
  defp chart_paths(points, max_y) when is_list(points) do
    values = Enum.map(points, fn {_dt, v} -> v end)

    case values do
      [] ->
        %{line: "", area: "", min: 0.0, max: 0.0, avg: 0.0, latest: nil}

      _ ->
        min_v = Enum.min(values, fn -> 0 end)
        max_v = Enum.max(values, fn -> 0 end)
        avg_v = Enum.sum(values) / length(values)
        latest = List.last(values)

        # Use fixed max when provided (percent scale), otherwise auto-scale with padding
        chart_max =
          cond do
            is_number(max_y) and max_y > 0 -> max_y
            max_v > 0 -> max_v * 1.1
            true -> 1.0
          end

        coords =
          Enum.with_index(values)
          |> Enum.map(fn {v, idx} ->
            x = idx_to_x(idx, length(values))
            y = value_to_y(v, 0, chart_max)
            {x, y}
          end)

        line = line_path(coords)
        area = area_path(coords)

        %{line: line, area: area, min: min_v, max: max_v, avg: avg_v, latest: latest}
    end
  end

  defp chart_max_from_value(_max_v, _unit, scale_max)
       when is_number(scale_max) and scale_max > 0 do
    scale_max
  end

  defp chart_max_from_value(max_v, _unit, _scale_max) when is_number(max_v) and max_v > 0 do
    max_v * 1.1
  end

  defp chart_max_from_value(_, _unit, _scale_max), do: 1.0

  defp combined_chart_max(series_data, unit) when is_list(series_data) do
    max_v =
      series_data
      |> Enum.map(&Map.get(&1.paths, :max))
      |> Enum.filter(&is_number/1)
      |> Enum.max(fn -> 0.0 end)

    chart_max_from_value(max_v, unit, scale_max_for_unit(unit))
  end

  defp combined_chart_max(_series_data, unit),
    do: chart_max_from_value(nil, unit, scale_max_for_unit(unit))

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

        tick_indices(len, tick_count)
        |> Enum.map(fn idx ->
          {dt, _v} = Enum.at(points, idx)
          {idx_to_x(idx, len), time_label(dt)}
        end)
    end
  end

  defp x_ticks(_points, _compact), do: []

  defp y_ticks(max_v, compact, unit) when is_number(max_v) and max_v > 0 do
    ticks = if compact, do: 3, else: 5

    0..ticks
    |> Enum.map(fn idx ->
      value = max_v * idx / ticks
      {value_to_y(value, 0, max_v), format_value(value, unit)}
    end)
  end

  defp y_ticks(_max_v, _compact, unit),
    do: [{value_to_y(0, 0, 1), format_value(0, unit)}]

  defp tick_indices(len, tick_count) when tick_count >= len do
    0..(len - 1)
    |> Enum.to_list()
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
      {series, counter_rate_points(sorted_points, series, max_speed)}
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
    {{dt, value}, [{dt, 0.0} | acc]}
  end

  defp counter_rate_step({dt, value}, {{prev_dt, prev_value}, acc}, series, max_speed) do
    diff = DateTime.diff(dt, prev_dt, :second)
    rate = counter_rate(diff, value, prev_value, series, max_speed)
    {{dt, value}, [{dt, rate} | acc]}
  end

  defp counter_rate(diff, _value, _prev_value, _series, _max_speed) when diff <= 0, do: 0.0

  defp counter_rate(diff, value, prev_value, series, max_speed) do
    value
    |> counter_delta(prev_value, series)
    |> Kernel./(diff)
    |> clamp_rate(max_speed)
  end

  defp counter_delta(current, previous, series) when is_number(current) and is_number(previous) do
    if current >= previous do
      current - previous
    else
      rollover_delta(current, previous, series)
    end
  end

  defp counter_delta(_, _, _), do: 0.0

  defp rollover_delta(current, previous, series) do
    max_value = counter_max(series, previous)

    if max_value > previous do
      max_value - previous + current
    else
      0.0
    end
  end

  defp counter_max(series, previous) do
    series_label = to_string(series || "")

    cond do
      String.contains?(series_label, "HC") -> @counter_max_64
      previous > @counter_max_32 -> @counter_max_64
      true -> @counter_max_32
    end
  end

  defp clamp_rate(rate, max_speed)
       when is_number(rate) and is_number(max_speed) and max_speed > 0 do
    if rate > max_speed do
      max_speed
    else
      rate
    end
  end

  defp clamp_rate(rate, _max_speed), do: rate

  defp value_to_y(_v, min_v, max_v) when min_v == max_v, do: round(@chart_height / 2)

  defp value_to_y(v, min_v, max_v) do
    usable = @chart_height - @chart_pad * 2
    scaled = (v - min_v) / (max_v - min_v)
    round(@chart_height - @chart_pad - scaled * usable)
  end

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
    0..(length(xs) - 2)
    |> Enum.map(fn i ->
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
    0..(n - 1)
    |> Enum.map(fn i -> slope_at(i, n, deltas) end)
  end

  defp slope_at(0, _n, deltas), do: Enum.at(deltas, 0) || 0.0
  defp slope_at(i, n, deltas) when i == n - 1, do: Enum.at(deltas, n - 2) || 0.0

  defp slope_at(i, _n, deltas) do
    d0 = Enum.at(deltas, i - 1)
    d1 = Enum.at(deltas, i)
    if d0 * d1 <= 0, do: 0.0, else: (d0 + d1) / 2
  end

  defp adjust_slopes(base, deltas) do
    0..(length(deltas) - 1)
    |> Enum.reduce(base, fn i, acc ->
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
    0..(n - 2)
    |> Enum.map(fn i ->
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

  defp chart_points(points, unit, compact, cap) when is_list(points) do
    points
    |> maybe_densify(unit, compact, cap)
    |> maybe_smooth(unit, compact)
  end

  defp chart_points(points, _unit, _compact, _cap), do: points

  defp maybe_densify(points, :bytes_per_sec, compact, cap) do
    factor = if compact, do: 2, else: 4
    densified = densify_points(points, factor)
    limit_points(densified, cap)
  end

  defp maybe_densify(points, _unit, _compact, _cap), do: points

  defp maybe_smooth(points, :bytes_per_sec, compact) do
    window = if compact, do: 1, else: 2
    smooth_points(points, window)
  end

  defp maybe_smooth(points, _unit, _compact), do: points

  defp densify_points([], _factor), do: []
  defp densify_points([_] = points, _factor), do: points

  defp densify_points(points, factor) when is_list(points) and factor > 1 do
    points
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.reduce([List.first(points)], fn segment, acc ->
      acc ++ densify_segment(segment, factor)
    end)
  end

  defp densify_points(points, _factor), do: points

  defp densify_segment([{dt0, v0}, {dt1, v1}], factor) do
    total_secs = max(DateTime.diff(dt1, dt0, :second), 1)

    intermediates =
      1..(factor - 1)
      |> Enum.map(fn i ->
        t = i / factor
        dt = DateTime.add(dt0, round(total_secs * t), :second)
        v = v0 + (v1 - v0) * t
        {dt, v}
      end)

    intermediates ++ [{dt1, v1}]
  end

  defp smooth_points(points, window) when is_list(points) and window > 0 do
    values = Enum.map(points, fn {_dt, v} -> v end)
    len = length(values)

    smoothed =
      values
      |> Enum.with_index()
      |> Enum.map(fn {_v, idx} ->
        from = max(idx - window, 0)
        to = min(idx + window, len - 1)
        slice = Enum.slice(values, from..to)
        Enum.sum(slice) / max(length(slice), 1)
      end)

    Enum.zip(Enum.map(points, &elem(&1, 0)), smoothed)
  end

  defp smooth_points(points, _window), do: points

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

  defp points_cap(_), do: @max_points

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

  defp median_delta_seconds(_), do: {:error, :no_deltas}

  defp limit_points(points, max_points) when is_list(points) and length(points) > max_points do
    total = length(points)
    step = Float.ceil(total / max_points) |> trunc()
    sampled = Enum.take_every(points, step)
    sampled = if length(sampled) > max_points, do: Enum.take(sampled, max_points), else: sampled

    case {sampled, List.last(points)} do
      {[], _} ->
        []

      {sampled, last_all} ->
        sampled =
          case {List.first(points), List.first(sampled)} do
            {nil, _} -> sampled
            {first_all, first_all} -> sampled
            {first_all, _} -> List.replace_at(sampled, 0, first_all)
          end

        if List.last(sampled) == last_all do
          sampled
        else
          List.replace_at(sampled, length(sampled) - 1, last_all)
        end
    end
  end

  defp limit_points(points, _max_points), do: points

  defp idx_to_x(_idx, 0), do: @chart_pad
  defp idx_to_x(0, _len), do: @chart_pad

  defp idx_to_x(idx, len) when len > 1 do
    usable = @chart_width - @chart_pad * 2
    round(@chart_pad + idx / (len - 1) * usable)
  end

  defp series_color(index) do
    # Nocturne cyber accent palette
    colors = [
      {"#00E676", "rgba(0,230,118,0.25)"},
      {"#00D8FF", "rgba(0,216,255,0.25)"},
      {"#A855F7", "rgba(168,85,247,0.25)"},
      {"#FF2A7A", "rgba(255,42,122,0.25)"},
      {"#FF9A00", "rgba(255,154,0,0.25)"},
      {"#FBBF24", "rgba(251,191,36,0.25)"}
    ]

    Enum.at(colors, rem(index, length(colors)))
  end

  defp dt_label(%DateTime{} = dt), do: Calendar.strftime(dt, "%b %-d %H:%M")
  defp dt_label(_), do: ""

  defp scale_max_for_unit(:percent), do: 100.0
  defp scale_max_for_unit(_), do: nil

  defp unit_for_series(series, spec, rate_mode) do
    cond do
      rate_mode == :counter ->
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

  defp combined_unit(_), do: :number

  defp unit_to_string(unit) do
    case unit do
      :percent -> "percent"
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
  defp traffic_series?(_), do: false

  # Compute utilization percentage from current value and max speed
  defp compute_utilization(value, max_speed)
       when is_number(value) and is_number(max_speed) and max_speed > 0 do
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
    # Rate mode: :counter (compute deltas) or :none (use values directly)
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
      |> assign(Map.drop(assigns, [:panel_assigns]))
      |> assign(panel_assigns || %{})
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
    series
    |> Enum.map(fn item ->
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

    series_points
    |> Enum.with_index()
    |> Enum.map(fn {{series, points}, idx} ->
      series_data_for_points(series, points, idx, spec, rate_mode, compact, max_speed)
    end)
  end

  defp series_data_for_points(series, points, idx, spec, rate_mode, compact, max_speed) do
    effective_max = if traffic_series?(series), do: max_speed, else: nil
    {stroke, _fill} = series_color(idx)
    display_name = humanize_series_name(series || "series")
    unit = unit_for_series(series, spec, rate_mode)
    points = Enum.sort_by(points, fn {dt, _} -> DateTime.to_unix(dt, :millisecond) end)
    cap = points_cap(points)
    points = limit_points(points, cap)
    chart_points = chart_points(points, unit, compact, cap)
    scale_max = scale_max_for_unit(unit)
    paths = chart_paths(chart_points, scale_max)
    utilization = compute_utilization(paths.avg, effective_max)
    chart_max = chart_max_from_value(paths.max, unit, scale_max)

    %{
      series: display_name,
      raw_series: series,
      paths: paths,
      stroke: stroke,
      idx: idx,
      point_data: Enum.map(chart_points, fn {dt, v} -> %{dt: dt_label(dt), v: v} end),
      unit: unit,
      raw_points: points,
      x_ticks: x_ticks(points, compact),
      y_ticks: y_ticks(chart_max, compact, unit),
      chart_max: chart_max,
      first_dt: series_first_dt(points),
      last_dt: series_last_dt(points),
      max_speed: effective_max,
      utilization: utilization
    }
  end

  defp resolve_chart_groups(
         series_data,
         combine_all_series,
         chart_mode,
         max_speed,
         compact,
         combined_title
       ) do
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
    chart_max = combined_chart_max(traffic_series, unit)
    x_ticks = first_series && x_ticks(first_series.raw_points || [], compact)
    y_ticks = y_ticks(chart_max, compact, unit)

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
    unit = combined_unit(series_data)
    chart_max = combined_chart_max(series_data, unit)
    x_ticks = first_series && x_ticks(first_series.raw_points || [], compact)
    y_ticks = y_ticks(chart_max, compact, unit)

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
    >
      <div class="flex items-center justify-between gap-3 mb-2">
        <div class="flex items-center gap-2 min-w-0">
          <span
            class="inline-block size-2 rounded-full shrink-0"
            style={"background-color: #{@data.stroke}"}
          />
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
              <span
                class="inline-block size-2 rounded-full shrink-0"
                style={"background-color: #{series.stroke}"}
              />
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
            <span
              class="inline-block size-1.5 rounded-full"
              style={"background-color: #{series.stroke}"}
            />
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
    series_points
    |> Enum.find_value(fn {_series, points} ->
      case points do
        [{%DateTime{} = dt, _} | _] -> dt
        _ -> nil
      end
    end)
  end

  defp first_dt(_), do: nil

  defp last_dt(series_points) when is_list(series_points) do
    series_points
    |> Enum.find_value(fn {_series, points} ->
      case List.last(points) do
        {%DateTime{} = dt, _} -> dt
        _ -> nil
      end
    end)
  end

  defp last_dt(_), do: nil

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
