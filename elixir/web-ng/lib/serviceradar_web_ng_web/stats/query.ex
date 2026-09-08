defmodule ServiceRadarWebNGWeb.Stats.Query do
  @moduledoc """
  Raw SRQL queries for dashboard stats cards using pre-computed CAGGs.

  These functions return the raw SRQL query strings that use the `rollup_stats:<type>`
  pattern to query pre-computed continuous aggregates instead of counting rows at query time.
  """

  @default_time_window "last_24h"
  @log_severity_values %{
    fatal: ~w(fatal emergency alert),
    error: ~w(error err critical),
    warning: ~w(warning warn),
    info: ~w(info information informational notice),
    debug: ~w(debug trace)
  }
  @otel_severity_prefixes %{
    fatal: ~w(fatal),
    error: ~w(error),
    warning: ~w(warn),
    info: ~w(info),
    debug: ~w(debug trace)
  }
  @severity_number_values %{
    fatal: Enum.to_list(21..24),
    error: Enum.to_list(17..20),
    warning: Enum.to_list(13..16),
    info: Enum.to_list(9..12),
    debug: Enum.to_list(1..8)
  }

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

    filters =
      []
      |> maybe_add_filter("service_name", service_name)
      |> Enum.join(" ")

    if filters == "" do
      base
    else
      "#{base} #{filters}"
    end
  end

  @doc """
  Return the canonical `severity_text` values used for a log severity group.

  Log severity filters are case-insensitive in both SRQL data and stats queries,
  matching the rollup CAGG's `lower(severity_text)` groups. OTel SDK enum names
  are included so a card click returns the same rows the rollup counted.
  """
  @spec log_severity_values(atom() | [atom()]) :: [String.t()]
  def log_severity_values(levels) when is_list(levels) do
    levels
    |> Enum.flat_map(&log_severity_values/1)
    |> Enum.uniq()
  end

  def log_severity_values(level) when is_atom(level) do
    canonical = Map.fetch!(@log_severity_values, level)

    otel =
      @otel_severity_prefixes
      |> Map.fetch!(level)
      |> Enum.flat_map(&otel_severity_values/1)

    canonical ++ otel
  end

  @doc "Build an exact-match SRQL severity filter for one or more log severity groups."
  @spec log_severity_filter(atom() | [atom()]) :: String.t()
  def log_severity_filter(levels) do
    levels = List.wrap(levels)
    text_values = levels |> log_severity_values() |> Enum.join(",")
    number_values = levels |> log_severity_number_values() |> Enum.join(",")

    "severity:(#{text_values}) severity_number:(#{number_values}) severity_match:any"
  end

  @doc "Build a log data query for a severity group using the shared severity mapping."
  @spec logs_severity_data_query(atom() | [atom()], keyword()) :: String.t()
  def logs_severity_data_query(levels, opts \\ []) do
    time = Keyword.get(opts, :time, @default_time_window)
    sort = Keyword.get(opts, :sort, "timestamp:desc")
    limit = Keyword.get(opts, :limit)

    base = "in:logs #{log_severity_filter(levels)} time:#{time} sort:#{sort}"

    if is_integer(limit) and limit > 0 do
      "#{base} limit:#{limit}"
    else
      base
    end
  end

  @doc "Build a log count query for a severity group using the shared severity mapping."
  @spec logs_severity_count_query(atom() | [atom()], keyword()) :: String.t()
  def logs_severity_count_query(levels, opts \\ []) do
    time = Keyword.get(opts, :time, @default_time_window)
    alias_name = Keyword.get(opts, :alias, "total")

    ~s|in:logs #{log_severity_filter(levels)} time:#{time} stats:"count() as #{alias_name}"|
  end

  defp otel_severity_values(prefix) do
    ["severity_number_#{prefix}" | Enum.map(2..4, &"severity_number_#{prefix}#{&1}")]
  end

  defp log_severity_number_values(levels) do
    levels
    |> Enum.flat_map(&Map.fetch!(@severity_number_values, &1))
    |> Enum.uniq()
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
  Build SRQL query for span RED (rate/errors/duration) stats.

  Returns: total, errors, slow, error_rate, avg_duration_ms, p50_duration_ms,
  p95_duration_ms, max_duration_ms.
  Uses the `spans_red_1h` CAGG computed over ALL spans (not just slow samples).
  """
  @spec metrics_red(keyword()) :: String.t()
  def metrics_red(opts \\ []) do
    time = Keyword.get(opts, :time, @default_time_window)
    service_name = Keyword.get(opts, :service_name)

    base = "in:otel_traces time:#{time} rollup_stats:red"

    if is_binary(service_name) and service_name != "" do
      "#{base} service_name:\"#{escape_value(service_name)}\""
    else
      base
    end
  end

  @doc """
  Build SRQL query for anomaly and at-risk capacity finding counts.

  Returns: total, anomalies, at_risk, critical, high.
  """
  @spec anomaly_findings(keyword()) :: String.t()
  def anomaly_findings(opts \\ []) do
    time = Keyword.get(opts, :time, @default_time_window)

    "in:events time:#{time} rollup_stats:anomaly_findings"
  end

  @doc "Build the event-list drill-down query for anomaly finding rollup cards."
  @spec anomaly_findings_data_query(keyword()) :: String.t()
  def anomaly_findings_data_query(opts \\ []), do: finding_rollup_data_query(:anomaly, opts)

  @doc "Build the event-list drill-down query for at-risk capacity finding rollup cards."
  @spec capacity_at_risk_data_query(keyword()) :: String.t()
  def capacity_at_risk_data_query(opts \\ []), do: finding_rollup_data_query(:capacity_at_risk, opts)

  @doc "Build the event-list drill-down query for the combined health findings rollup card."
  @spec health_findings_data_query(keyword()) :: String.t()
  def health_findings_data_query(opts \\ []), do: finding_rollup_data_query(:health, opts)

  @spec finding_rollup_data_query(atom() | String.t(), keyword()) :: String.t()
  def finding_rollup_data_query(kind, opts \\ []) do
    time = Keyword.get(opts, :time, @default_time_window)
    sort = Keyword.get(opts, :sort, "time:desc")
    limit = Keyword.get(opts, :limit)
    kind = normalize_finding_rollup_kind(kind)

    base = "in:events finding_rollup:#{kind} time:#{time} sort:#{sort}"

    if is_integer(limit) and limit > 0 do
      "#{base} limit:#{limit}"
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

    if filters == "" do
      base
    else
      "#{base} #{filters}"
    end
  end

  # Escape special characters in SRQL filter values
  defp escape_value(value) when is_binary(value) do
    value
    |> String.replace("\\", "\\\\")
    |> String.replace("\"", "\\\"")
  end

  defp normalize_finding_rollup_kind(:anomaly), do: "anomaly"
  defp normalize_finding_rollup_kind(:capacity_at_risk), do: "capacity_at_risk"
  defp normalize_finding_rollup_kind(:health), do: "health"
  defp normalize_finding_rollup_kind("anomaly"), do: "anomaly"
  defp normalize_finding_rollup_kind("capacity_at_risk"), do: "capacity_at_risk"
  defp normalize_finding_rollup_kind("health"), do: "health"
  defp normalize_finding_rollup_kind(other), do: raise(ArgumentError, "unknown finding rollup kind: #{inspect(other)}")

  defp maybe_add_filter(filters, _field, nil), do: filters
  defp maybe_add_filter(filters, _field, ""), do: filters

  defp maybe_add_filter(filters, field, value) when is_binary(value) do
    [~s|#{field}:"#{escape_value(value)}"| | filters]
  end
end
