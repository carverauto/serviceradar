defmodule ServiceRadarWebNGWeb.InterfaceLive.MetricsQuery do
  @moduledoc false

  alias ServiceRadarWebNGWeb.InterfaceLive.SnmpMetricNames

  @counter_window "last_24h"
  @counter_bucket "1m"
  @buckets_per_window 24 * 60
  @minimum_limit 3_600

  def build_snmp_counter_query(device_uid, if_index, metric_names, opts \\ []) do
    names = normalize_metric_names(metric_names)
    time_range = Keyword.get(opts, :time_range, @counter_window)
    bucket = Keyword.get(opts, :bucket, @counter_bucket)
    limit = Keyword.get(opts, :limit, row_limit(names))

    [
      "in:snmp_metrics",
      ~s(device_id:"#{escape_value(device_uid)}"),
      "if_index:#{if_index}",
      metric_filter(names),
      "time:#{time_range}",
      "bucket:#{bucket}",
      "agg:rate",
      "series:metric_name",
      "limit:#{limit}"
    ]
    |> Enum.reject(&blank?/1)
    |> Enum.join(" ")
  end

  def row_limit(metric_names) do
    metric_count =
      metric_names
      |> normalize_metric_names()
      |> length()
      |> max(1)

    max(@minimum_limit, metric_count * @buckets_per_window)
  end

  defp metric_filter([]), do: nil

  defp metric_filter(metric_names) do
    values = Enum.map_join(metric_names, ",", &~s("#{escape_value(&1)}"))

    "metric_name:[#{values}]"
  end

  defp normalize_metric_names(metric_names) when is_list(metric_names) do
    metric_names
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == "" or &1 == "Unknown"))
    |> SnmpMetricNames.expand()
  end

  defp normalize_metric_names(_metric_names), do: []

  defp escape_value(value) do
    value
    |> to_string()
    |> String.replace("\\", "\\\\")
    |> String.replace("\"", "\\\"")
  end

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(_), do: false
end
