defmodule ServiceRadarWebNGWeb.Dashboard.Plugins.Timeseries.Paths do
  @moduledoc false

  @chart_width 800
  @chart_height 140
  @chart_left_pad 72
  @chart_right_pad 32
  @chart_top_pad 12
  @chart_bottom_pad 24
  @label_char_width 7
  @label_margin 18
  @max_chart_left_pad 160

  def chart_width, do: @chart_width
  def chart_height, do: @chart_height
  def chart_left_pad, do: @chart_left_pad
  def chart_right_pad, do: @chart_right_pad
  def chart_top_pad, do: @chart_top_pad
  def chart_bottom_pad, do: @chart_bottom_pad

  def chart_left_pad(y_ticks) when is_list(y_ticks) do
    label_width =
      y_ticks
      |> Enum.map(fn
        {_y, label} when is_binary(label) -> String.length(label) * @label_char_width
        {_y, label} -> label |> to_string() |> String.length() |> Kernel.*(@label_char_width)
      end)
      |> Enum.max(fn -> 0 end)

    @chart_left_pad
    |> max(label_width + @label_margin)
    |> min(@max_chart_left_pad)
  end

  def chart_left_pad(_y_ticks), do: @chart_left_pad

  def chart_paths(points, domain), do: chart_paths(points, domain, %{})

  def chart_paths(points, %{min: min_v, max: max_v, scale: scale}, opts) when is_list(points) do
    values =
      points
      |> Enum.map(fn {_dt, v} -> v end)
      |> Enum.filter(&is_number/1)

    case values do
      [] ->
        Map.merge(%{line: "", area: ""}, stats(points))

      _ ->
        point_stats = stats(points)

        coords =
          points
          |> Enum.with_index()
          |> Enum.map(fn
            {{dt, v}, idx} when is_number(v) ->
              x = datetime_to_x(dt, points, opts) || idx_to_x(idx, length(points), opts)

              case value_to_y(v, min_v, max_v, scale) do
                y when is_number(y) -> {x, y}
                _ -> :gap
              end

            {_point, _idx} ->
              :gap
          end)

        segments = contiguous_segments(coords)

        Map.merge(
          %{
            line: segments_path(segments, &line_path/1),
            area: segments_path(segments, &area_path/1)
          },
          point_stats
        )
    end
  end

  def chart_paths(points, max_y, opts) when is_list(points) do
    %{max: max_v} = stats(points)

    chart_max =
      cond do
        is_number(max_y) and max_y > 0 -> max_y
        max_v > 0 -> max_v * 1.1
        true -> 1.0
      end

    chart_paths(points, %{min: 0.0, max: chart_max, scale: :linear}, opts)
  end

  def stats(points) when is_list(points) do
    values =
      points
      |> Enum.map(fn {_dt, v} -> v end)
      |> Enum.filter(&is_number/1)

    case values do
      [] ->
        %{min: 0.0, max: 0.0, avg: 0.0, latest: nil}

      _ ->
        %{
          min: Enum.min(values, fn -> 0 end),
          max: Enum.max(values, fn -> 0 end),
          avg: Enum.sum(values) / length(values),
          latest: List.last(values)
        }
    end
  end

  def idx_to_x(idx, len), do: idx_to_x(idx, len, %{})

  def idx_to_x(_idx, 0, opts), do: geometry(opts).left_pad
  def idx_to_x(0, _len, opts), do: geometry(opts).left_pad

  def idx_to_x(idx, len, opts) when len > 1 do
    geometry = geometry(opts)
    usable = @chart_width - geometry.left_pad - geometry.right_pad
    round(geometry.left_pad + idx / (len - 1) * usable)
  end

  def datetime_to_x(%DateTime{} = dt, points), do: datetime_to_x(dt, points, %{})

  def datetime_to_x(%DateTime{} = dt, points, opts) when is_list(points) do
    times =
      points
      |> Enum.map(fn
        {%DateTime{} = point_dt, _value} -> DateTime.to_unix(point_dt, :millisecond)
        _point -> nil
      end)
      |> Enum.reject(&is_nil/1)

    case times do
      [] ->
        nil

      [only] ->
        if DateTime.to_unix(dt, :millisecond) == only, do: geometry(opts).left_pad

      _ ->
        target = DateTime.to_unix(dt, :millisecond)
        first = List.first(times)
        last = List.last(times)

        cond do
          target < first or target > last ->
            nil

          last == first ->
            geometry(opts).left_pad

          true ->
            geometry = geometry(opts)
            usable = @chart_width - geometry.left_pad - geometry.right_pad
            Float.round(geometry.left_pad + (target - first) / (last - first) * usable, 2)
        end
    end
  end

  def datetime_to_x(_dt, _points, _opts), do: nil

  def value_to_y(_v, min_v, max_v) when min_v == max_v, do: round(@chart_height / 2)

  def value_to_y(v, min_v, max_v) do
    usable = @chart_height - @chart_top_pad - @chart_bottom_pad
    scaled = (v - min_v) / (max_v - min_v)
    round(@chart_height - @chart_bottom_pad - scaled * usable)
  end

  def value_to_y(v, min_v, max_v, :log) when v > 0 and min_v > 0 and max_v > min_v do
    usable = @chart_height - @chart_top_pad - @chart_bottom_pad
    min_log = :math.log10(min_v)
    max_log = :math.log10(max_v)
    scaled = (:math.log10(v) - min_log) / (max_log - min_log)
    round(@chart_height - @chart_bottom_pad - scaled * usable)
  end

  def value_to_y(v, min_v, max_v, :linear), do: value_to_y(v, min_v, max_v)
  def value_to_y(_v, _min_v, _max_v, :log), do: nil
  def value_to_y(v, min_v, max_v, _scale), do: value_to_y(v, min_v, max_v)

  defp line_path([]), do: ""

  defp line_path([{x, y}]) do
    "M #{fmt(x - 2)},#{fmt(y)} L #{fmt(x + 2)},#{fmt(y)}"
  end

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

  defp contiguous_segments(coords) do
    coords
    |> Enum.chunk_by(&(&1 == :gap))
    |> Enum.reject(fn
      [:gap | _] -> true
      [] -> true
      _segment -> false
    end)
  end

  defp segments_path(segments, path_fun) do
    segments
    |> Enum.map(path_fun)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(" ")
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
    xs
    |> length()
    |> initial_slopes(deltas)
    |> adjust_slopes(deltas)
  end

  defp initial_slopes(n, deltas), do: Enum.map(0..(n - 1), fn i -> slope_at(i, n, deltas) end)
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
  defp baseline_y, do: @chart_height - @chart_bottom_pad

  defp geometry(opts) do
    %{
      left_pad:
        opts
        |> geometry_value([:chart_left_pad, :left_pad, "chart_left_pad", "left_pad"], @chart_left_pad)
        |> clamp_pad(@chart_left_pad, @max_chart_left_pad),
      right_pad: geometry_value(opts, [:chart_right_pad, :right_pad, "chart_right_pad", "right_pad"], @chart_right_pad)
    }
  end

  defp geometry_value(opts, keys, default) when is_map(opts) do
    Enum.find_value(keys, default, fn key ->
      case Map.get(opts, key) do
        value when is_number(value) -> value
        _ -> nil
      end
    end)
  end

  defp geometry_value(opts, keys, default) when is_list(opts) do
    Enum.find_value(keys, default, fn key ->
      case Keyword.get(opts, key) do
        value when is_number(value) -> value
        _ -> nil
      end
    end)
  end

  defp geometry_value(_opts, _keys, default), do: default

  defp clamp_pad(value, min_value, max_value), do: value |> max(min_value) |> min(max_value)
end
