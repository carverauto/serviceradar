defmodule ServiceRadar.Analytics.StarRocks.ShadowParity do
  @moduledoc """
  Exact synthetic shadow-parity comparison for a dataset interval.

  Compares counts, additive totals, NULL distributions, sampling-weighted
  totals and interval rates. A mismatch blocks cutover; this module does not
  switch readers.
  """

  alias ServiceRadar.Analytics.StarRocks.Identity
  alias ServiceRadar.Analytics.StarRocks.Rows

  @type dataset :: Identity.dataset()

  @spec summarize(dataset(), [map()]) :: map()
  def summarize(dataset, rows) when is_list(rows) do
    encoded = Rows.encode(dataset, rows)
    numeric = numeric_fields(dataset)

    totals =
      Map.new(numeric, fn field ->
        values = Enum.map(encoded, &Map.get(&1, field))
        {field <> "_total", sum_present(values)}
      end)

    nulls =
      Map.new(null_fields(dataset), fn field ->
        {"null_" <> field, Enum.count(encoded, &is_nil(Map.get(&1, field)))}
      end)

    sampling_weighted = sampling_weighted_bytes(dataset, encoded)
    {start_at, end_at} = interval(dataset, encoded)
    duration_s = max(interval_seconds(start_at, end_at), 1)

    Map.merge(
      %{
        dataset: dataset,
        count: length(encoded),
        identities: encoded |> Enum.map(&identity(dataset, &1)) |> Enum.sort(),
        interval_start: start_at,
        interval_end: end_at,
        duration_s: duration_s,
        rate_count_per_s: length(encoded) / duration_s
      },
      Map.merge(totals, Map.merge(nulls, sampling_weighted))
    )
  end

  @spec compare(map(), map()) :: :ok | {:mismatch, map()}
  def compare(source, destination) when is_map(source) and is_map(destination) do
    keys =
      (Map.keys(source) ++ Map.keys(destination))
      |> Enum.uniq()
      |> Enum.reject(&(&1 in [:interval_start, :interval_end]))

    diffs =
      Enum.reduce(keys, %{}, fn key, acc ->
        left = Map.get(source, key)
        right = Map.get(destination, key)

        if values_equal?(left, right) do
          acc
        else
          Map.put(acc, key, %{source: left, destination: right})
        end
      end)

    if diffs == %{}, do: :ok, else: {:mismatch, diffs}
  end

  defp numeric_fields(:flows), do: ["bytes_in", "bytes_out", "packets_in", "packets_out"]
  defp numeric_fields(:metrics), do: ["value"]
  defp numeric_fields(:logs), do: ["severity_number"]
  defp numeric_fields(:events), do: ["severity_id"]

  defp null_fields(:flows), do: ["bytes_out", "src_endpoint_port", "dst_endpoint_port"]
  defp null_fields(:metrics), do: ["if_index", "unit", "agent_id"]
  defp null_fields(:logs), do: ["severity_text", "body", "service_name"]
  defp null_fields(:events), do: ["severity", "source"]

  defp sampling_weighted_bytes(:flows, encoded) do
    weighted =
      Enum.reduce(encoded, 0, fn row, acc ->
        bytes = row["bytes_in"] || 0
        rate = row["sampling_rate"] || 1
        acc + bytes * rate
      end)

    %{"sampling_weighted_bytes_in" => weighted}
  end

  defp sampling_weighted_bytes(_dataset, _encoded), do: %{}

  defp identity(:metrics, row), do: Identity.metric_identity(row)
  defp identity(dataset, row), do: Identity.record_id(dataset, row)

  defp interval(dataset, encoded) do
    times =
      encoded
      |> Enum.map(&time_value(dataset, &1))
      |> Enum.reject(&is_nil/1)
      |> Enum.sort()

    {List.first(times), List.last(times)}
  end

  defp time_value(:flows, row), do: row["time"]
  defp time_value(:events, row), do: row["time"]
  defp time_value(_dataset, row), do: row["timestamp"]

  defp interval_seconds(nil, _), do: 1
  defp interval_seconds(_, nil), do: 1

  defp interval_seconds(start_at, end_at) when is_binary(start_at) and is_binary(end_at) do
    with {:ok, start_dt, _} <- DateTime.from_iso8601(normalize_iso(start_at)),
         {:ok, end_dt, _} <- DateTime.from_iso8601(normalize_iso(end_at)) do
      max(DateTime.diff(end_dt, start_dt, :second), 1)
    else
      _ -> 1
    end
  end

  defp interval_seconds(_, _), do: 1

  defp normalize_iso(value) do
    if String.contains?(value, "Z") or String.contains?(value, "+") do
      value
    else
      value <> "Z"
    end
  end

  defp sum_present(values) do
    Enum.reduce(values, 0, fn
      value, acc when is_number(value) -> acc + value
      _missing, acc -> acc
    end)
  end

  defp values_equal?(left, right) when is_float(left) and is_float(right),
    do: abs(left - right) < 1.0e-9

  defp values_equal?(left, right), do: left == right
end
