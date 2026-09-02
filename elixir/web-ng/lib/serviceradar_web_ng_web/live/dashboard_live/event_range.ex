defmodule ServiceRadarWebNGWeb.DashboardLive.EventRange do
  @moduledoc false

  @plot_left 36
  @plot_width 580

  @spec x(non_neg_integer(), pos_integer()) :: integer()
  def x(index, count) do
    @plot_left + round(@plot_width * index / max(count - 1, 1))
  end

  @spec buckets(term()) :: {:ok, [map()]} | :error
  def buckets(points) when is_list(points) and points != [] do
    count = length(points)

    case Enum.reduce_while(Enum.with_index(points), {:ok, []}, fn {point, index}, {:ok, acc} ->
           case bucket_start(point) do
             {:ok, start_time} ->
               end_time = start_time |> DateTime.add(3_600, :second) |> DateTime.add(-1, :microsecond)

               bucket = %{
                 x: x(index, count),
                 start: DateTime.to_iso8601(start_time),
                 end: DateTime.to_iso8601(end_time)
               }

               {:cont, {:ok, [bucket | acc]}}

             :error ->
               {:halt, :error}
           end
         end) do
      {:ok, buckets} -> {:ok, Enum.reverse(buckets)}
      :error -> :error
    end
  end

  def buckets(_), do: :error

  @spec selection(term(), term()) :: {:ok, {DateTime.t(), DateTime.t()}} | :error
  def selection(points, %{"start" => start, "end" => finish}) when is_binary(start) and is_binary(finish) do
    with {:ok, start_time, _offset} <- DateTime.from_iso8601(start),
         {:ok, end_time, _offset} <- DateTime.from_iso8601(finish),
         :lt <- DateTime.compare(start_time, end_time),
         {:ok, buckets} <- buckets(points),
         start_index when is_integer(start_index) <- Enum.find_index(buckets, &(&1.start == start)),
         end_index when is_integer(end_index) <- Enum.find_index(buckets, &(&1.end == finish)),
         true <- start_index <= end_index do
      {:ok, {start_time, end_time}}
    else
      _ -> :error
    end
  end

  def selection(_points, _params), do: :error

  defp bucket_start(%{bucket: %DateTime{time_zone: "Etc/UTC", utc_offset: 0, std_offset: 0} = bucket}),
    do: {:ok, DateTime.truncate(bucket, :second)}

  defp bucket_start(%{bucket: %NaiveDateTime{} = bucket}) do
    {:ok, bucket |> NaiveDateTime.truncate(:second) |> DateTime.from_naive!("Etc/UTC")}
  end

  defp bucket_start(_), do: :error
end
