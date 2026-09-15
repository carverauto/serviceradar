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

  @availability_sources [
    {"metric_type:icmp metric_name:icmp_available", :status},
    {"metric_type:sweep metric_name:sweep.host.icmp_available", :status}
  ]

  def load(srql_module, device_uids, scope, opts) when is_list(device_uids) do
    load_sources(@sources, srql_module, device_uids, scope, opts)
  end

  def load_availability(srql_module, device_uids, scope, opts) when is_list(device_uids) do
    load_sources(@availability_sources, srql_module, device_uids, scope, Keyword.put(opts, :aggregate, :min), :bucket)
  end

  defp load_sources(sources, srql_module, device_uids, scope, opts, selection \\ :device) do
    sources
    |> Enum.reduce_while({:ok, [], device_uids}, fn
      _source, {:ok, batches, []} ->
        {:halt, {:ok, batches, []}}

      {filter, unit}, {:ok, batches, missing} ->
        query = query(missing, filter, opts)

        case srql_module.query(query, %{scope: scope}) do
          {:ok, %{"results" => rows}} when is_list(rows) ->
            rows = normalize_rows(rows, missing, unit, Keyword.fetch!(opts, :aggregate))
            missing = remaining_devices(rows, missing, selection)
            {:cont, {:ok, [rows | batches], missing}}

          {:error, _} = error ->
            {:halt, error}

          _ ->
            {:halt, {:error, :invalid_icmp_metrics_response}}
        end
    end)
    |> case do
      {:ok, batches, _missing} ->
        {:ok, select_rows(Enum.reverse(batches), selection)}

      error ->
        error
    end
  end

  defp remaining_devices(_rows, device_uids, :bucket), do: device_uids

  defp remaining_devices(rows, device_uids, :device) do
    found = MapSet.new(rows, & &1["series"])
    Enum.reject(device_uids, &MapSet.member?(found, &1))
  end

  defp select_rows(batches, :device), do: List.flatten(batches)

  defp select_rows(batches, :bucket) do
    # Preferred observations, including failures, win only their own bucket.
    # A producer may have stopped mid-window while sweep observations continue.
    batches
    |> Enum.flat_map(fn rows ->
      rows
      |> Enum.group_by(&bucket_key/1)
      |> Enum.map(fn {_key, observations} -> Enum.min_by(observations, & &1["value"]) end)
    end)
    |> Enum.uniq_by(&bucket_key/1)
  end

  defp bucket_key(row), do: {row["series"], timestamp_key(row["timestamp"])}

  defp timestamp_key(%DateTime{} = timestamp), do: DateTime.to_unix(timestamp, :microsecond)

  defp timestamp_key(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, timestamp, _offset} -> timestamp_key(timestamp)
      _ -> value
    end
  end

  defp timestamp_key(value), do: value

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

        if MapSet.member?(wanted, uid) and valid_value?(value, unit) do
          value = if aggregate == :avg, do: latency_ms(value, unit), else: value
          [Map.put(row, "value", value)]
        else
          []
        end

      _ ->
        []
    end)
  end

  defp valid_value?(value, :status), do: value in [0, 0.0, 1, 1.0]
  defp valid_value?(value, _unit), do: is_number(value)

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
