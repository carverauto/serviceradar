defmodule ServiceRadarWebNGWeb.InterfaceLive.MetricsQuery do
  @moduledoc false

  alias ServiceRadarWebNGWeb.DeviceLive.SysmonMetrics.Query
  alias ServiceRadarWebNGWeb.InterfaceLive.SnmpMetricNames

  @counter_window "last_24h"

  # The row limit is a guard, not a page size, so it is sized for the finest
  # bucket a caller may ask for (1m over a day) rather than for the default.
  @buckets_per_window 24 * 60
  @minimum_limit 3_600

  def build_snmp_counter_query(device_uid, if_index, metric_names, opts \\ []) do
    names = normalize_metric_names(metric_names)
    time_range = Keyword.get(opts, :time_range, @counter_window)
    # A chart a few hundred pixels wide cannot draw a day of 1m buckets: that is
    # 1,440 points a series, most of them landing on a pixel already taken. The
    # window picks the bucket instead, as the sysmon charts do. agg:rate averages
    # the per-sample rates inside a bucket, so a coarser one stays a true rate.
    bucket = Keyword.get(opts, :bucket) || Query.bucket_for_time_range(time_range)
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
