defmodule ServiceRadarWebNGWeb.EventLive.AnomalyMetricQueries do
  @moduledoc """
  The metric queries an anomaly event's detail page tries, in order, to chart the series the
  anomaly was raised on: for an SNMP interface a rate series, an average fallback and raw
  points; for any metric an averaged series and raw points.

  `ServiceRadarWebNGWeb.EventLive.Show` builds its chart queries only through `variants/5`, so
  the shapes it can send are the shapes this module produces.
  """

  # Keep room for multi-series interface rates across ±2h at 1–5m buckets.
  @snmp_metrics_limit 3_600

  @doc "Every query variant for one time range, most preferred first; `[]` without a device."
  @spec variants(String.t() | nil, integer() | nil, String.t() | nil, boolean(), String.t() | nil) :: [String.t()]
  def variants(device_uid, if_index, metric_name, snmp?, time_range)
      when is_binary(device_uid) and device_uid != "" and is_binary(time_range) do
    escaped_uid = escape_value(device_uid)
    metric_filter = metric_name_filter(metric_name)

    snmp_queries =
      if snmp? and is_integer(if_index) and if_index > 0 do
        base =
          "in:snmp_metrics device_id:\"#{escaped_uid}\" if_index:#{if_index} time:#{time_range}"

        [
          # Rate series (preferred for counters like ifOutOctets)
          Enum.join(
            Enum.reject(
              [
                base,
                metric_filter,
                "bucket:5m",
                "agg:rate",
                "series:metric_name",
                "limit:#{@snmp_metrics_limit}"
              ],
              &is_nil/1
            ),
            " "
          ),
          # Avg fallback without rate transform
          Enum.join(
            Enum.reject(
              [
                base,
                metric_filter,
                "bucket:5m",
                "agg:avg",
                "series:metric_name",
                "limit:#{@snmp_metrics_limit}"
              ],
              &is_nil/1
            ),
            " "
          ),
          # Raw points for the specific metric
          if metric_filter do
            "#{base} #{metric_filter} sort:timestamp:asc limit:#{@snmp_metrics_limit}"
          end
        ]
      else
        []
      end

    generic_queries =
      if is_binary(metric_name) and metric_name != "" do
        [
          Enum.join(
            [
              "in:timeseries_metrics",
              "device_id:\"#{escaped_uid}\"",
              ~s(metric_name:"#{escape_value(metric_name)}"),
              "time:#{time_range}",
              "bucket:5m",
              "agg:avg",
              "series:metric_name",
              "limit:#{@snmp_metrics_limit}"
            ],
            " "
          ),
          Enum.join(
            [
              "in:timeseries_metrics",
              "device_id:\"#{escaped_uid}\"",
              ~s(metric_name:"#{escape_value(metric_name)}"),
              "time:#{time_range}",
              "sort:timestamp:asc",
              "limit:#{@snmp_metrics_limit}"
            ],
            " "
          )
        ]
      else
        []
      end

    Enum.reject(snmp_queries ++ generic_queries, &is_nil/1)
  end

  def variants(_device_uid, _if_index, _metric_name, _snmp?, _time_range), do: []

  defp metric_name_filter(metric_name) when is_binary(metric_name) and metric_name != "" do
    ~s(metric_name:"#{escape_value(metric_name)}")
  end

  defp metric_name_filter(_), do: nil

  defp escape_value(value) when is_binary(value) do
    value
    |> String.replace("\\", "\\\\")
    |> String.replace("\"", "\\\"")
  end

  defp escape_value(other), do: escape_value(to_string(other))
end
