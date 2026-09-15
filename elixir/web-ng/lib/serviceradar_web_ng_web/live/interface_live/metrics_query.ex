defmodule ServiceRadarWebNGWeb.InterfaceLive.MetricsQuery do
  @moduledoc false

  alias ServiceRadarWebNGWeb.DeviceLive.SysmonMetrics.Query
  alias ServiceRadarWebNGWeb.InterfaceLive.SnmpMetricNames
  alias ServiceRadarWebNGWeb.MetricWindowComponents

  @counter_window "last_24h"
  @counter_bucket "1m"
  @buckets_per_window 24 * 60
  @minimum_limit 3_600

  def window_opts(range) do
    range = MetricWindowComponents.normalize_range(range)
    bucket = if range == @counter_window, do: @counter_bucket, else: Query.bucket_for_time_range(range)
    [time_range: range, bucket: bucket]
  end

  def build_snmp_counter_query(device_uid, if_index, metric_names, opts \\ []) do
    names = normalize_metric_names(metric_names)
    build_counter_query(device_uid, "if_index:#{if_index}", names, "metric_name", row_limit(names), opts)
  end

  def build_snmp_counter_batch_query(device_uid, interfaces) when is_list(interfaces) and interfaces != [] do
    indexes = interfaces |> Enum.map(& &1.if_index) |> Enum.uniq() |> Enum.sort()
    names = interfaces |> Enum.flat_map(& &1.metrics_selected) |> normalize_metric_names()

    # The name union can return metrics selected on another interface. Reserve
    # their rows too, including both partial buckets at the window boundaries,
    # before the caller filters each interface's selected metrics.
    limit = length(indexes) * max(@minimum_limit, length(names) * (@buckets_per_window + 1))
    index_filter = "if_index:(#{Enum.join(indexes, ",")})"
    build_counter_query(device_uid, index_filter, names, "interface_metric", limit, [])
  end

  defp build_counter_query(device_uid, index_filter, names, series, default_limit, opts) do
    time_range = Keyword.get(opts, :time_range, @counter_window)
    bucket = Keyword.get(opts, :bucket, @counter_bucket)
    limit = Keyword.get(opts, :limit, default_limit)

    [
      "in:snmp_metrics",
      ~s(device_id:"#{escape_value(device_uid)}"),
      index_filter,
      metric_filter(names),
      "time:#{time_range}",
      "bucket:#{bucket}",
      "agg:rate",
      "series:#{series}",
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
