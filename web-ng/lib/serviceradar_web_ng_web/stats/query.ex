defmodule ServiceRadarWebNGWeb.Stats.Query do
  @moduledoc """
  Raw SRQL queries for dashboard stats cards using pre-computed CAGGs.

  These functions return the raw SRQL query strings that use the `rollup_stats:<type>`
  pattern to query pre-computed continuous aggregates instead of counting rows at query time.
  """

  @default_time_window "last_24h"

  @doc """
  Build SRQL query for logs severity stats.

  Returns counts by severity level: total, fatal, error, warning, info, debug.
  Uses the `logs_severity_stats_5m` CAGG.
  """
  @spec logs_severity(keyword()) :: String.t()
  def logs_severity(opts \\ []) do
    time = Keyword.get(opts, :time, @default_time_window)
    service_name = Keyword.get(opts, :service_name)

    base = "in:logs time:#{time} rollup_stats:severity"

    if is_binary(service_name) and service_name != "" do
      "#{base} service_name:\"#{escape_value(service_name)}\""
    else
      base
    end
  end

  @doc """
  Build SRQL query for traces summary stats.

  Returns: total, errors, avg_duration_ms, p95_duration_ms.
  Uses the `traces_stats_5m` CAGG.
  """
  @spec traces_summary(keyword()) :: String.t()
  def traces_summary(opts \\ []) do
    time = Keyword.get(opts, :time, @default_time_window)
    service_name = Keyword.get(opts, :service_name)

    base = "in:otel_traces time:#{time} rollup_stats:summary"

    if is_binary(service_name) and service_name != "" do
      "#{base} service_name:\"#{escape_value(service_name)}\""
    else
      base
    end
  end

  @doc """
  Build SRQL query for services availability stats.

  Returns: total, available, unavailable, availability_pct.
  Uses the `services_availability_5m` CAGG.
  """
  @spec services_availability(keyword()) :: String.t()
  def services_availability(opts \\ []) do
    time = Keyword.get(opts, :time, @default_time_window)
    service_name = Keyword.get(opts, :service_name)
    service_type = Keyword.get(opts, :service_type)

    base = "in:services time:#{time} rollup_stats:availability"

    filters =
      []
      |> maybe_add_filter("service_name", service_name)
      |> maybe_add_filter("service_type", service_type)
      |> Enum.join(" ")

    if filters != "" do
      "#{base} #{filters}"
    else
      base
    end
  end

  # Escape special characters in SRQL filter values
  defp escape_value(value) when is_binary(value) do
    value
    |> String.replace("\\", "\\\\")
    |> String.replace("\"", "\\\"")
  end

  defp maybe_add_filter(filters, _field, nil), do: filters
  defp maybe_add_filter(filters, _field, ""), do: filters

  defp maybe_add_filter(filters, field, value) when is_binary(value) do
    [~s|#{field}:"#{escape_value(value)}"| | filters]
  end
end
