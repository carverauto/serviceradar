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
