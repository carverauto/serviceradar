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

  def chart_points(points, _unit, _compact, _cap) when is_list(points), do: points

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
    min_max_envelope(points, max_points)
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

  defp min_max_envelope(points, max_points) when max_points < 3 do
    points
    |> take_endpoints()
    |> Enum.take(max_points)
  end

  defp min_max_envelope(points, max_points) do
    first = List.first(points)
    last = List.last(points)
    middle = points |> Enum.drop(1) |> Enum.drop(-1)
    bucket_count = max(div(max_points - 2, 2), 1)

    envelope =
      middle
      |> bucket_by_index(bucket_count)
      |> Enum.flat_map(&bucket_extremes/1)

    [first | envelope]
    |> append_last(last)
    |> Enum.uniq()
    |> trim_preserving_last(max_points, last)
  end

  defp take_endpoints([]), do: []
  defp take_endpoints([_point] = points), do: points
  defp take_endpoints(points), do: [List.first(points), List.last(points)]

  defp append_last([], nil), do: []
  defp append_last(points, nil), do: points
  defp append_last(points, last), do: points ++ [last]

  defp trim_preserving_last(points, max_points, _last) when length(points) <= max_points, do: points

  defp trim_preserving_last(points, max_points, last) do
    points
    |> Enum.take(max(max_points - 1, 0))
    |> append_last(last)
    |> Enum.uniq()
  end

  defp bucket_by_index([], _bucket_count), do: []

  defp bucket_by_index(points, bucket_count) do
    points
    |> Enum.with_index()
    |> Enum.group_by(fn {_point, idx} -> min(div(idx * bucket_count, length(points)), bucket_count - 1) end)
    |> Enum.sort_by(fn {bucket_idx, _points} -> bucket_idx end)
    |> Enum.map(fn {_bucket_idx, indexed_points} -> Enum.map(indexed_points, &elem(&1, 0)) end)
  end

  defp bucket_extremes([]), do: []

  defp bucket_extremes(points) do
    points = Enum.filter(points, fn {_dt, value} -> is_number(value) end)

    if points == [] do
      []
    else
      min_point = Enum.min_by(points, fn {_dt, value} -> value end)
      max_point = Enum.max_by(points, fn {_dt, value} -> value end)

      [min_point, max_point]
      |> Enum.uniq()
      |> Enum.sort_by(fn {dt, _value} -> DateTime.to_unix(dt, :microsecond) end)
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
end
