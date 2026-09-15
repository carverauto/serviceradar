defmodule ServiceRadarWebNGWeb.DeviceLive.ICMPData do
  @moduledoc """
  ICMP latency buckets from dedicated checks, sweeps, and legacy metric rows.

  One source is selected per device and requested window: dedicated latency first,
  then sweep latency, then legacy ICMP metrics. Missing devices alone fall back,
  so overlapping producers never duplicate or average each other's observations.
  """

  @sources [
    {"metric_type:icmp metric_name:icmp_response_time_ns", :nanoseconds},
    {"metric_type:sweep metric_name:sweep.host.icmp_response_time_ns", :nanoseconds},
    {~s(metric_type:icmp !metric_name:["icmp_response_time_ns","icmp_packet_loss","icmp_available"]), :legacy}
  ]

  def load(srql_module, device_uids, scope, opts) when is_list(device_uids) do
    @sources
    |> Enum.reduce_while({:ok, [], device_uids}, fn
      _source, {:ok, batches, []} ->
        {:halt, {:ok, batches, []}}

      {filter, unit}, {:ok, batches, missing} ->
        query = query(missing, filter, opts)

        case srql_module.query(query, %{scope: scope}) do
          {:ok, %{"results" => rows}} when is_list(rows) ->
            rows = normalize_rows(rows, missing, unit, Keyword.fetch!(opts, :aggregate))
            found = MapSet.new(rows, & &1["series"])
            missing = Enum.reject(missing, &MapSet.member?(found, &1))
            {:cont, {:ok, [rows | batches], missing}}

          {:error, _} = error ->
            {:halt, error}

          _ ->
            {:halt, {:error, :invalid_icmp_metrics_response}}
        end
    end)
    |> case do
      {:ok, batches, _missing} -> {:ok, batches |> Enum.reverse() |> List.flatten()}
      error -> error
    end
  end

  defp query(device_uids, filter, opts) do
    uids = Enum.map_join(device_uids, ",", &quote_uid/1)

    Enum.join(
      [
        "in:timeseries_metrics",
        filter,
        "uid:(#{uids})",
        "time:#{Keyword.fetch!(opts, :time_range)}",
        "bucket:#{Keyword.fetch!(opts, :bucket)}",
        "agg:#{Keyword.fetch!(opts, :aggregate)}",
        "series:uid",
        "sort:timestamp:asc",
        "limit:#{Keyword.fetch!(opts, :limit)}"
      ],
      " "
    )
  end

  defp normalize_rows(rows, device_uids, unit, aggregate) do
    wanted = MapSet.new(device_uids)

    Enum.flat_map(rows, fn
      %{"series" => uid, "value" => value} = row ->
        value = number(value)

        if MapSet.member?(wanted, uid) and is_number(value) do
          value = if aggregate == :avg, do: latency_ms(value, unit), else: value
          [Map.put(row, "value", value)]
        else
          []
        end

      _ ->
        []
    end)
  end

  defp latency_ms(value, :nanoseconds), do: value / 1_000_000.0
  defp latency_ms(value, :legacy) when value > 1_000_000, do: value / 1_000_000.0
  defp latency_ms(value, :legacy), do: value * 1.0

  defp number(value) when is_number(value), do: value

  defp number(value) when is_binary(value) do
    case Float.parse(String.trim(value)) do
      {parsed, ""} -> parsed
      _ -> nil
    end
  end

  defp number(_value), do: nil

  defp quote_uid(uid) do
    escaped = uid |> String.replace("\\", "\\\\") |> String.replace("\"", "\\\"")
    "\"#{escaped}\""
  end
end
