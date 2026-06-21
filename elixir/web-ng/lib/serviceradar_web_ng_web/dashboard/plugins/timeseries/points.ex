defmodule ServiceRadarWebNGWeb.Dashboard.Plugins.Timeseries.Points do
  @moduledoc false

  alias ServiceRadarWebNGWeb.Dashboard.Plugins.Timeseries.Metrics
  alias ServiceRadarWebNGWeb.Dashboard.Plugins.Timeseries.Paths

  @max_points 800

  def chart_max_from_value(_max_v, _unit, scale_max) when is_number(scale_max) and scale_max > 0, do: scale_max
  def chart_max_from_value(max_v, _unit, _scale_max) when is_number(max_v) and max_v > 0, do: max_v * 1.1
  def chart_max_from_value(_, _unit, _scale_max), do: 1.0

  def combined_chart_max(series_data, unit) when is_list(series_data) do
    max_v =
      series_data
      |> Enum.map(&Map.get(&1.paths, :max))
      |> Enum.filter(&is_number/1)
      |> Enum.max(fn -> 0.0 end)

    chart_max_from_value(max_v, unit, Metrics.scale_max_for_unit(unit))
  end

  def x_ticks(points, compact) when is_list(points) do
    len = length(points)

    case len do
      0 ->
        []

      1 ->
        [{Paths.idx_to_x(0, len), time_label(elem(List.first(points), 0))}]

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
          {Paths.idx_to_x(idx, len), time_label(dt)}
        end)
    end
  end

  def x_ticks(_points, _compact), do: []

  def y_ticks(max_v, compact, unit) when is_number(max_v) and max_v > 0 do
    ticks = if compact, do: 3, else: 5

    Enum.map(0..ticks, fn idx ->
      value = max_v * idx / ticks
      {Paths.value_to_y(value, 0, max_v), Metrics.format_value(value, unit)}
    end)
  end

  def y_ticks(_max_v, _compact, unit), do: [{Paths.value_to_y(0, 0, 1), Metrics.format_value(0, unit)}]

  def chart_points(points, unit, compact, cap) when is_list(points) do
    points
    |> maybe_densify(unit, compact, cap)
    |> maybe_smooth(unit, compact)
  end

  def chart_points(points, _unit, _compact, _cap), do: points

  def points_cap(points) when is_list(points) do
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

  def limit_points(points, max_points) when is_list(points) and length(points) > max_points do
    total = length(points)
    step = (total / max_points) |> Float.ceil() |> trunc()
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

  def limit_points(points, _max_points), do: points

  def dt_label(%DateTime{} = dt), do: Calendar.strftime(dt, "%b %-d %H:%M")
  def dt_label(_), do: ""

  def first_dt(series_points) when is_list(series_points) do
    Enum.find_value(series_points, fn {_series, points} ->
      case points do
        [{%DateTime{} = dt, _} | _] -> dt
        _ -> nil
      end
    end)
  end

  def last_dt(series_points) when is_list(series_points) do
    Enum.find_value(series_points, fn {_series, points} ->
      case List.last(points) do
        {%DateTime{} = dt, _} -> dt
        _ -> nil
      end
    end)
  end

  def series_first_dt([{%DateTime{} = dt, _} | _]), do: dt_label(dt)
  def series_first_dt(_), do: ""

  def series_last_dt(points) when is_list(points) do
    case List.last(points) do
      {%DateTime{} = dt, _} -> dt_label(dt)
      _ -> ""
    end
  end

  def series_last_dt(_), do: ""

  defp tick_indices(len, tick_count) when tick_count >= len, do: Enum.to_list(0..(len - 1))

  defp tick_indices(len, tick_count) when tick_count > 1 do
    0..(tick_count - 1)
    |> Enum.map(fn idx -> round(idx * (len - 1) / (tick_count - 1)) end)
    |> Enum.uniq()
  end

  defp tick_indices(_len, _tick_count), do: [0]

  defp time_label(%DateTime{} = dt), do: Calendar.strftime(dt, "%-I:%M %p")
  defp time_label(_), do: ""

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
      Enum.map(1..(factor - 1), fn i ->
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
end
