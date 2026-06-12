defmodule ServiceRadarWebNGWeb.Stats.Extract do
  @moduledoc """
  Extract and type-convert raw SRQL rollup stats responses.

  These functions unwrap the JSON payload from SRQL responses and convert
  values to appropriate Elixir types with sensible defaults.
  """

  @type logs_severity :: %{
          total: non_neg_integer(),
          fatal: non_neg_integer(),
          error: non_neg_integer(),
          warning: non_neg_integer(),
          info: non_neg_integer(),
          debug: non_neg_integer()
        }

  @type traces_summary :: %{
          total: non_neg_integer(),
          errors: non_neg_integer(),
          avg_duration_ms: float(),
          p95_duration_ms: float()
        }

  @type services_availability :: %{
          total: non_neg_integer(),
          available: non_neg_integer(),
          unavailable: non_neg_integer(),
          availability_pct: float()
        }

  @type metrics_red :: %{
          total: non_neg_integer(),
          slow_spans: non_neg_integer(),
          error_spans: non_neg_integer(),
          error_rate: float(),
          avg_duration_ms: float(),
          p50_duration_ms: float(),
          p95_duration_ms: float(),
          max_duration_ms: float(),
          sample_size: non_neg_integer()
        }

  @type anomaly_findings :: %{
          total: non_neg_integer(),
          anomalies: non_neg_integer(),
          at_risk: non_neg_integer(),
          critical: non_neg_integer(),
          high: non_neg_integer()
        }

  @doc """
  Extract logs severity stats from SRQL response.

  Returns a map with counts for each severity level.
  """
  @spec logs_severity({:ok, map()} | {:error, term()}) :: logs_severity()
  def logs_severity({:ok, %{"results" => [%{} = payload | _]}}) do
    %{
      total: to_int(Map.get(payload, "total", 0)),
      fatal: to_int(Map.get(payload, "fatal", 0)),
      error: to_int(Map.get(payload, "error", 0)),
      warning: to_int(Map.get(payload, "warning", 0)),
      info: to_int(Map.get(payload, "info", 0)),
      debug: to_int(Map.get(payload, "debug", 0))
    }
  end

  def logs_severity(_), do: empty_logs_severity()

  @doc """
  Return empty logs severity stats.
  """
  @spec empty_logs_severity() :: logs_severity()
  def empty_logs_severity do
    %{total: 0, fatal: 0, error: 0, warning: 0, info: 0, debug: 0}
  end

  @doc """
  Extract traces summary stats from SRQL response.

  Returns aggregate trace metrics including counts and latency percentiles.
  """
  @spec traces_summary({:ok, map()} | {:error, term()}) :: traces_summary()
  def traces_summary({:ok, %{"results" => [%{} = payload | _]}}) do
    %{
      total: to_int(Map.get(payload, "total", 0)),
      errors: to_int(Map.get(payload, "errors", 0)),
      avg_duration_ms: to_float(Map.get(payload, "avg_duration_ms", 0.0)),
      p95_duration_ms: to_float(Map.get(payload, "p95_duration_ms", 0.0))
    }
  end

  def traces_summary(_), do: empty_traces_summary()

  @doc """
  Return empty traces summary stats.
  """
  @spec empty_traces_summary() :: traces_summary()
  def empty_traces_summary do
    %{total: 0, errors: 0, avg_duration_ms: 0.0, p95_duration_ms: 0.0}
  end

  @doc """
  Extract span RED stats (`rollup_stats:red` over `spans_red_1h`) from an SRQL
  response.

  The payload carries `total`, `errors`, `slow`, `error_rate` (0-100 float),
  `avg_duration_ms`, `p50_duration_ms`, `p95_duration_ms`, and
  `max_duration_ms`. The result keeps the legacy metrics-summary key names
  (`slow_spans`, `error_spans`, `sample_size`) so stat cards keep working.
  """
  @spec metrics_red({:ok, map()} | {:error, term()}) :: metrics_red()
  def metrics_red({:ok, %{"results" => [%{} = payload | _]}}) do
    total = to_int(Map.get(payload, "total", 0))

    %{
      total: total,
      slow_spans: to_int(Map.get(payload, "slow", 0)),
      error_spans: to_int(Map.get(payload, "errors", 0)),
      error_rate: to_float(Map.get(payload, "error_rate", 0.0)),
      avg_duration_ms: to_float(Map.get(payload, "avg_duration_ms", 0.0)),
      p50_duration_ms: to_float(Map.get(payload, "p50_duration_ms", 0.0)),
      p95_duration_ms: to_float(Map.get(payload, "p95_duration_ms", 0.0)),
      max_duration_ms: to_float(Map.get(payload, "max_duration_ms", 0.0)),
      sample_size: total
    }
  end

  def metrics_red(_), do: empty_metrics_red()

  @doc """
  Return empty span RED stats.
  """
  @spec empty_metrics_red() :: metrics_red()
  def empty_metrics_red do
    %{
      total: 0,
      slow_spans: 0,
      error_spans: 0,
      error_rate: 0.0,
      avg_duration_ms: 0.0,
      p50_duration_ms: 0.0,
      p95_duration_ms: 0.0,
      max_duration_ms: 0.0,
      sample_size: 0
    }
  end

  @doc """
  Extract anomaly and at-risk capacity finding stats from an SRQL rollup response.
  """
  @spec anomaly_findings({:ok, map()} | {:error, term()}) :: anomaly_findings()
  def anomaly_findings({:ok, %{"results" => [%{} = payload | _]}}) do
    %{
      total: to_int(Map.get(payload, "total", 0)),
      anomalies: to_int(Map.get(payload, "anomalies", 0)),
      at_risk: to_int(Map.get(payload, "at_risk", 0)),
      critical: to_int(Map.get(payload, "critical", 0)),
      high: to_int(Map.get(payload, "high", 0))
    }
  end

  def anomaly_findings(_), do: empty_anomaly_findings()

  @doc """
  Return empty anomaly finding stats.
  """
  @spec empty_anomaly_findings() :: anomaly_findings()
  def empty_anomaly_findings do
    %{total: 0, anomalies: 0, at_risk: 0, critical: 0, high: 0}
  end

  @doc """
  Extract services availability stats from SRQL response.

  Returns counts of available/unavailable services and availability percentage.
  """
  @spec services_availability({:ok, map()} | {:error, term()}) :: services_availability()
  def services_availability({:ok, %{"results" => [%{} = payload | _]}}) do
    %{
      total: to_int(Map.get(payload, "total", 0)),
      available: to_int(Map.get(payload, "available", 0)),
      unavailable: to_int(Map.get(payload, "unavailable", 0)),
      availability_pct: to_float(Map.get(payload, "availability_pct", 0.0))
    }
  end

  def services_availability(_), do: empty_services_availability()

  @doc """
  Return empty services availability stats.
  """
  @spec empty_services_availability() :: services_availability()
  def empty_services_availability do
    %{total: 0, available: 0, unavailable: 0, availability_pct: 0.0}
  end

  # Type conversion helpers

  defp to_int(value) when is_integer(value), do: value
  defp to_int(value) when is_float(value), do: trunc(value)

  defp to_int(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} -> parsed
      _ -> 0
    end
  end

  defp to_int(_), do: 0

  defp to_float(value) when is_float(value), do: value
  defp to_float(value) when is_integer(value), do: value * 1.0

  defp to_float(value) when is_binary(value) do
    case Float.parse(String.trim(value)) do
      {parsed, ""} -> parsed
      {parsed, _} -> parsed
      _ -> 0.0
    end
  end

  defp to_float(_), do: 0.0
end
