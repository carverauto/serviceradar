defmodule ServiceRadarWebNGWeb.DeviceLive.ICMPData do
  @moduledoc """
  ICMP latency buckets from dedicated checks, sweeps, and legacy metric rows.

  One source is selected per device and time bucket: dedicated latency first,
  then sweep latency, then legacy ICMP metrics. A sparse preferred source must
  not hide the rest of a device's history. Overlapping producers never duplicate
  or average each other's observations.
  """

  @sources [
    {"metric_type:icmp metric_name:icmp_response_time_ns", :nanoseconds},
    {"metric_type:sweep metric_name:sweep.host.icmp_response_time_ns", :nanoseconds},
    {~s(metric_type:icmp !metric_name:["icmp_response_time_ns","icmp_packet_loss","icmp_available"]), :legacy}
  ]

  # A sweep reports a host available when any probe answers, ICMP or TCP.
  # Reading the ICMP-only gauge marked a host that blocks ping but answers on a
  # swept TCP port offline in every bucket.
  @availability_sources [
    {"metric_type:icmp metric_name:icmp_available", :status},
    {"metric_type:sweep metric_name:sweep.host.available", :status}
  ]

  def load(srql_module, device_uids, scope, opts) when is_list(device_uids) do
    load_sources(@sources, srql_module, device_uids, scope, opts, :latency)
  end

  @doc """
  Availability buckets for one device, one row per bucket whose `series` is the device uid.

  Each address the device is probed at is its own series (`target_device_ip`): a sweep of a
  device that holds several addresses writes one `sweep.host.available` sample per address.
  Within a bucket, the observer aggregate applies to each address on its own, and the device is
  then online when any of its addresses was. A selected observer owns the result, so any
  failure it saw on an address in the bucket marks that address offline (`min`). With no
  selection, availability wins across observers (`max`), matching the device's fallback
  availability policy.

  "Any address answered" matches the agent's sweep aggregator, which marks a multi-address
  device available when any address answers (`go/pkg/sweeper/sweeper_aggregators.go`,
  `IsAvailable = availableCount > 0`), and the merged resolver, which lets any decisive `up`
  win within the deciding class (`ServiceRadar.Inventory.Availability.Resolver`, rule 6).
  Aggregating every address of the device as one series let a single address that never
  answers, such as one the device no longer holds, mark every bucket offline.
  """
  def load_availability(srql_module, device_uid, scope, opts) when is_binary(device_uid) do
    aggregate = if is_binary(Keyword.get(opts, :agent_id)), do: :min, else: :max

    opts =
      opts
      |> Keyword.put(:aggregate, aggregate)
      |> Keyword.put(:series, "target_device_ip")

    load_sources(@availability_sources, srql_module, [device_uid], scope, opts, :availability)
  end

  defp load_sources(_sources, _srql_module, [], _scope, _opts, _selection), do: {:ok, []}

  defp load_sources(sources, srql_module, device_uids, scope, opts, selection) do
    sources
    |> Enum.reduce_while({:ok, []}, fn {filter, unit}, {:ok, batches} ->
      query = query(device_uids, filter, opts)

      case srql_module.query(query, %{scope: scope}) do
        {:ok, %{"results" => rows}} when is_list(rows) ->
          rows = normalize_rows(rows, device_uids, unit, opts)
          {:cont, {:ok, [rows | batches]}}

        {:error, _} = error ->
          {:halt, error}

        _ ->
          {:halt, {:error, :invalid_icmp_metrics_response}}
      end
    end)
    |> case do
      {:ok, batches} ->
        {:ok, select_rows(Enum.reverse(batches), selection)}

      error ->
        error
    end
  end

  defp select_rows(batches, :latency) do
    batches
    |> List.flatten()
    |> Enum.uniq_by(&bucket_key/1)
  end

  defp select_rows(batches, :availability) do
    # Within a source, the device is online in a bucket when any of its addresses was. A
    # preferred source's observations, including failures, then win only their own bucket:
    # a producer may have stopped mid-window while sweep observations continue.
    batches
    |> Enum.flat_map(fn rows ->
      rows
      |> Enum.group_by(&bucket_key/1)
      |> Enum.map(fn {_key, addresses} -> Enum.max_by(addresses, & &1["value"]) end)
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

    [
      "in:timeseries_metrics",
      filter,
      "uid:(#{uids})",
      agent_filter(Keyword.get(opts, :agent_id)),
      "time:#{Keyword.fetch!(opts, :time_range)}",
      "bucket:#{Keyword.fetch!(opts, :bucket)}",
      "agg:#{Keyword.fetch!(opts, :aggregate)}",
      "series:#{Keyword.get(opts, :series, "uid")}",
      "sort:timestamp:asc",
      "limit:#{Keyword.fetch!(opts, :limit)}"
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
  end

  defp agent_filter(nil), do: nil
  defp agent_filter(agent_id), do: "agent_id:#{quote_uid(agent_id)}"

  defp normalize_rows(rows, device_uids, unit, opts) do
    aggregate = Keyword.fetch!(opts, :aggregate)
    owner = series_owner(device_uids, Keyword.get(opts, :series, "uid"))

    Enum.flat_map(rows, fn
      %{"series" => series, "value" => value} = row ->
        value = number(value)
        uid = owner.(series)

        if is_binary(uid) and valid_value?(value, unit) do
          value = if aggregate == :avg, do: latency_ms(value, unit), else: value
          [%{row | "series" => uid, "value" => value}]
        else
          []
        end

      _ ->
        []
    end)
  end

  # The device a row belongs to. A per-address series is one device's address, since an
  # address-split query is only ever made for a single device.
  defp series_owner(device_uids, "uid") do
    wanted = MapSet.new(device_uids)
    fn uid -> if MapSet.member?(wanted, uid), do: uid end
  end

  defp series_owner([device_uid], _address_series), do: fn _address -> device_uid end

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
