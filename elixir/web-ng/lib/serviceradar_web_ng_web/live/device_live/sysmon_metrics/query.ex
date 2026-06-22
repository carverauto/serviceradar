defmodule ServiceRadarWebNGWeb.DeviceLive.SysmonMetrics.Query do
  @moduledoc false

  import ServiceRadarWebNGWeb.DeviceLive.SysmonMetrics.Common, only: [escape_value: 1]

  def timeseries_metric_query(metric_type, metric_name, filter_tokens, series_field, limit, opts \\ []) do
    series_field =
      case series_field do
        nil -> nil
        "" -> nil
        other -> other |> to_string() |> String.trim()
      end

    tokens =
      if Keyword.get(opts, :bucket?, true) do
        [
          "in:timeseries_metrics",
          ~s|metric_type:"#{escape_value(metric_type)}"|,
          ~s|metric_name:"#{escape_value(metric_name)}"|,
          "time:#{Keyword.get(opts, :time_range, "last_24h")}",
          "bucket:5m",
          "agg:#{Keyword.get(opts, :agg, "avg")}"
        ]
      else
        [
          "in:timeseries_metrics",
          ~s|metric_type:"#{escape_value(metric_type)}"|,
          ~s|metric_name:"#{escape_value(metric_name)}"|,
          "time:#{Keyword.get(opts, :time_range, "last_24h")}"
        ]
      end

    tokens =
      tokens
      |> maybe_add_token("series", series_field)
      |> Kernel.++(filter_tokens)
      |> Kernel.++(["sort:timestamp:desc"])
      |> maybe_add_limit(limit)

    Enum.join(tokens, " ")
  end

  defp maybe_add_limit(tokens, nil), do: tokens
  defp maybe_add_limit(tokens, ""), do: tokens
  defp maybe_add_limit(tokens, limit), do: tokens ++ ["limit:#{limit}"]

  defp maybe_add_token(tokens, _key, nil), do: tokens
  defp maybe_add_token(tokens, _key, ""), do: tokens

  defp maybe_add_token(tokens, key, value) do
    tokens ++ ["#{key}:#{value}"]
  end
end
