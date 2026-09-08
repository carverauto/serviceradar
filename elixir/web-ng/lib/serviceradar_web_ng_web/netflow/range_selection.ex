defmodule ServiceRadarWebNGWeb.Netflow.RangeSelection do
  @moduledoc false

  @type interval :: %{x: float(), start: String.t(), end: String.t()}
  @type canonical_interval :: %{start: String.t(), end: String.t()}

  @spec canonical_intervals(list()) :: [canonical_interval()]
  def canonical_intervals(points) when is_list(points) do
    Enum.map(canonical_intervals_with_times(points), &Map.take(&1, [:start, :end]))
  end

  def canonical_intervals(_points), do: []

  @spec intervals(list(), :lines | :grid | String.t(), number()) :: [interval()]
  def intervals(points, mode, width)
      when is_list(points) and mode in [:lines, :grid, "lines", "grid"] and is_number(width) and width > 0 do
    canonical = canonical_intervals(points)
    xs = x_positions(length(canonical), mode, width)

    Enum.zip_with(canonical, xs, fn interval, x ->
      %{x: x, start: interval.start, end: interval.end}
    end)
  end

  def intervals(_points, _mode, _width), do: []

  @spec x_positions(non_neg_integer(), :lines | :grid | String.t(), number()) :: [float()]
  def x_positions(count, mode, width)
      when is_integer(count) and count > 0 and mode in [:lines, "lines"] and is_number(width) and width > 0 do
    width = width * 1.0

    case count do
      1 -> [width / 2]
      _ -> for index <- 0..(count - 1), do: index / (count - 1) * width
    end
  end

  def x_positions(count, mode, width)
      when is_integer(count) and count > 0 and mode in [:grid, "grid"] and is_number(width) and width > 0 do
    width = width * 1.0
    band_width = width / count

    for index <- 0..(count - 1), do: (index + 0.5) * band_width
  end

  def x_positions(_count, _mode, _width), do: []

  @spec validate(map(), list()) :: {:ok, %{start: String.t(), end: String.t()}} | :error
  def validate(%{"start" => start_raw, "end" => end_raw} = params, points)
      when map_size(params) == 2 and is_binary(start_raw) and is_binary(end_raw) and is_list(points) do
    canonical = canonical_intervals_with_times(points)

    with {:ok, start_time, _offset} <- DateTime.from_iso8601(start_raw),
         {:ok, end_time, _offset} <- DateTime.from_iso8601(end_raw),
         :lt <- DateTime.compare(start_time, end_time),
         start_index when is_integer(start_index) <- find_boundary(canonical, :start_time, start_time),
         end_index when is_integer(end_index) <- find_boundary(canonical, :end_time, end_time),
         true <- end_index >= start_index do
      start_interval = Enum.at(canonical, start_index)
      end_interval = Enum.at(canonical, end_index)

      {:ok, %{start: start_interval.start, end: end_interval.end}}
    else
      _ -> :error
    end
  end

  def validate(_params, _points), do: :error

  defp canonical_intervals_with_times(points) do
    Enum.flat_map(points, fn
      %{bucket_start: bucket_start, bucket_end: bucket_end} ->
        with {:ok, start_time} <- utc_datetime(bucket_start),
             {:ok, end_exclusive} <- utc_datetime(bucket_end),
             :lt <- DateTime.compare(start_time, end_exclusive) do
          end_time = DateTime.add(end_exclusive, -1, :microsecond)

          [
            %{
              start_time: start_time,
              end_time: end_time,
              start: DateTime.to_iso8601(start_time),
              end: DateTime.to_iso8601(end_time)
            }
          ]
        else
          _ -> []
        end

      _ ->
        []
    end)
  end

  defp utc_datetime(%DateTime{} = datetime), do: {:ok, datetime}

  defp utc_datetime(%NaiveDateTime{} = datetime) do
    {:ok, DateTime.from_naive!(datetime, "Etc/UTC")}
  end

  defp utc_datetime(_datetime), do: :error

  defp find_boundary(intervals, field, datetime) do
    Enum.find_index(intervals, &(DateTime.compare(Map.fetch!(&1, field), datetime) == :eq))
  end
end
