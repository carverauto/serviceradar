defmodule ServiceRadarWebNGWeb.Dashboard.Plugins.Timeseries.Points do
  @moduledoc false

  alias ServiceRadarWebNGWeb.Dashboard.Plugins.Timeseries.Metrics
  alias ServiceRadarWebNGWeb.Dashboard.Plugins.Timeseries.Paths

  @max_points 800
  @linear_padding_ratio 0.05
  @constant_padding_ratio 0.05
  @log_padding_ratio 0.05
  @log_constant_factor :math.sqrt(10)

  def chart_max_from_value(_max_v, _unit, scale_max) when is_number(scale_max) and scale_max > 0, do: scale_max
  def chart_max_from_value(max_v, _unit, _scale_max) when is_number(max_v) and max_v > 0, do: max_v * 1.1
  def chart_max_from_value(_, _unit, _scale_max), do: 1.0

  def y_domain(points, unit, scale_mode \\ :linear)

  def y_domain(points, unit, :log) when is_list(points) do
    values =
      points
      |> numeric_values()
      |> Enum.filter(&(&1 > 0))

    case values do
      [] -> y_domain(points, unit, :linear)
      _ -> values |> padded_log_domain() |> maybe_clamp_percent_domain(unit)
    end
  end

  def y_domain(points, unit, _scale_mode) when is_list(points) do
    points
    |> numeric_values()
    |> padded_linear_domain()
    |> maybe_clamp_percent_domain(unit)
  end

  def y_domain(_points, unit, scale_mode), do: y_domain([], unit, scale_mode)

  def combined_y_domain(series_data, unit, scale_mode) when is_list(series_data) do
    series_data
    |> Enum.flat_map(&Map.get(&1, :raw_points, []))
    |> y_domain(unit, scale_mode)
  end

  def scale_mode(:log), do: :log
  def scale_mode("log"), do: :log
  def scale_mode("logarithmic"), do: :log
  def scale_mode(_), do: :linear

  def x_ticks(points, compact, opts \\ %{})

  def x_ticks(points, compact, opts) when is_list(points) do
    len = length(points)

    case len do
      0 ->
        []

      1 ->
        {dt, _value} = List.first(points)
        [{Paths.datetime_to_x(dt, points, opts) || Paths.idx_to_x(0, len, opts), canonical_time(dt)}]

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
          {Paths.datetime_to_x(dt, points, opts) || Paths.idx_to_x(idx, len, opts), canonical_time(dt)}
        end)
    end
  end

  def x_ticks(_points, _compact, _opts), do: []

  def y_ticks(%{min: min_v, max: max_v, scale: scale}, compact, unit)
      when is_number(min_v) and is_number(max_v) and max_v > min_v do
    ticks = if compact, do: 3, else: 5

    Enum.map(0..ticks, fn idx ->
      value = tick_value(min_v, max_v, scale, idx, ticks)
      {Paths.value_to_y(value, min_v, max_v, scale), Metrics.format_value(value, unit)}
    end)
  end

  def y_ticks(max_v, compact, unit) when is_number(max_v) and max_v > 0 do
    y_ticks(%{min: 0.0, max: max_v, scale: :linear}, compact, unit)
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

  def series_first_dt([{%DateTime{} = dt, _} | _]), do: dt
  def series_first_dt(_), do: nil

  def series_last_dt(points) when is_list(points) do
    case List.last(points) do
      {%DateTime{} = dt, _} -> dt
      _ -> nil
    end
  end

  def series_last_dt(_), do: nil

  defp tick_indices(len, tick_count) when tick_count >= len, do: Enum.to_list(0..(len - 1))

  defp tick_indices(len, tick_count) when tick_count > 1 do
    0..(tick_count - 1)
    |> Enum.map(fn idx -> round(idx * (len - 1) / (tick_count - 1)) end)
    |> Enum.uniq()
  end

  defp tick_indices(_len, _tick_count), do: [0]

  defp canonical_time(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp canonical_time(_), do: ""

  defp tick_value(min_v, max_v, :log, idx, ticks) do
    min_log = :math.log10(min_v)
    max_log = :math.log10(max_v)
    :math.pow(10, min_log + (max_log - min_log) * idx / ticks)
  end

  defp tick_value(min_v, max_v, _scale, idx, ticks), do: min_v + (max_v - min_v) * idx / ticks

  defp numeric_values(points) do
    points
    |> Enum.map(fn {_dt, value} -> value end)
    |> Enum.filter(&is_number/1)
  end

  defp padded_linear_domain([]), do: %{min: 0.0, max: 1.0, scale: :linear}

  defp padded_linear_domain(values) do
    min_v = Enum.min(values)
    max_v = Enum.max(values)

    {domain_min, domain_max} =
      if min_v == max_v do
        pad = max(abs_value(max_v) * @constant_padding_ratio, 1.0)
        {min_v - pad, max_v + pad}
      else
        pad = max((max_v - min_v) * @linear_padding_ratio, 0.01)
        {min_v - pad, max_v + pad}
      end

    domain_min =
      if min_v >= 0 and domain_min < 0 do
        0.0
      else
        domain_min
      end

    %{min: domain_min * 1.0, max: domain_max * 1.0, scale: :linear}
  end

  defp padded_log_domain(values) do
    min_v = Enum.min(values)
    max_v = Enum.max(values)

    {domain_min, domain_max} =
      if min_v == max_v do
        {min_v / @log_constant_factor, max_v * @log_constant_factor}
      else
        min_log = :math.log10(min_v)
        max_log = :math.log10(max_v)
        pad = max((max_log - min_log) * @log_padding_ratio, 0.0)
        {:math.pow(10, min_log - pad), :math.pow(10, max_log + pad)}
      end

    %{min: domain_min * 1.0, max: domain_max * 1.0, scale: :log}
  end

  defp maybe_clamp_percent_domain(%{min: min_v, max: max_v} = domain, :percent) do
    min_v = if min_v >= 0, do: max(min_v, 0.0), else: min_v
    max_v = if max_v <= 100.0, do: min(max_v, 100.0), else: max_v

    if max_v > min_v do
      %{domain | min: min_v, max: max_v}
    else
      %{domain | min: min_v, max: min_v + 1.0}
    end
  end

  defp maybe_clamp_percent_domain(domain, _unit), do: domain

  defp abs_value(value) when value < 0, do: -value
  defp abs_value(value), do: value

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
