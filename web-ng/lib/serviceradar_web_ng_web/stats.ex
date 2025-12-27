defmodule ServiceRadarWebNGWeb.Stats do
  @moduledoc """
  Unified interface for fetching dashboard stats from pre-computed CAGGs.

  This module provides high-level functions to fetch stats for dashboard cards.
  It uses the new `rollup_stats:<type>` SRQL pattern which queries pre-computed
  continuous aggregates instead of counting rows at query time.

  ## Usage

      # Fetch logs severity breakdown
      summary = Stats.logs_severity()
      # => %{total: 1234, fatal: 1, error: 23, warning: 100, info: 1000, debug: 110}

      # Fetch traces summary
      traces = Stats.traces_summary()
      # => %{total: 567, errors: 12, avg_duration_ms: 45.2, p95_duration_ms: 120.5}

      # Fetch services availability
      services = Stats.services_availability()
      # => %{total: 50, available: 48, unavailable: 2, availability_pct: 96.0}

  ## Architecture

  The Stats subsystem follows a layered pattern:

  1. **Query** (`Stats.Query`) - Raw SRQL query strings
  2. **Extract** (`Stats.Extract`) - Parse responses into typed structs
  3. **Compute** (`Stats.Compute`) - Derive percentages, rates, changes

  This module combines all layers for convenience.
  """

  alias ServiceRadarWebNGWeb.Stats.{Query, Extract, Compute}

  @doc """
  Fetch logs severity stats using the rollup_stats pattern.

  Returns aggregated counts by severity level from the pre-computed CAGG.

  ## Options

    * `:time` - Time range filter (default: "last_24h")
    * `:service_name` - Filter by service name (optional)
    * `:srql_module` - SRQL module to use (default from config)

  ## Examples

      Stats.logs_severity()
      Stats.logs_severity(time: "last_1h")
      Stats.logs_severity(service_name: "api-gateway")
  """
  @spec logs_severity(keyword()) :: Extract.logs_severity()
  def logs_severity(opts \\ []) do
    srql_module = Keyword.get(opts, :srql_module, default_srql_module())
    actor = Keyword.get(opts, :actor)
    query = Query.logs_severity(opts)

    query
    |> srql_module.query(%{actor: actor})
    |> Extract.logs_severity()
  end

  @doc """
  Fetch traces summary stats using the rollup_stats pattern.

  Returns aggregated trace metrics from the pre-computed CAGG.

  ## Options

    * `:time` - Time range filter (default: "last_24h")
    * `:service_name` - Filter by service name (optional)
    * `:srql_module` - SRQL module to use (default from config)

  ## Examples

      Stats.traces_summary()
      Stats.traces_summary(time: "last_6h")
      Stats.traces_summary(service_name: "user-service")
  """
  @spec traces_summary(keyword()) :: Extract.traces_summary()
  def traces_summary(opts \\ []) do
    srql_module = Keyword.get(opts, :srql_module, default_srql_module())
    actor = Keyword.get(opts, :actor)
    query = Query.traces_summary(opts)

    query
    |> srql_module.query(%{actor: actor})
    |> Extract.traces_summary()
  end

  @doc """
  Fetch services availability stats using the rollup_stats pattern.

  Returns aggregated availability metrics from the pre-computed CAGG.

  ## Options

    * `:time` - Time range filter (default: "last_24h")
    * `:service_name` - Filter by service name (optional)
    * `:service_type` - Filter by service type (optional)
    * `:srql_module` - SRQL module to use (default from config)

  ## Examples

      Stats.services_availability()
      Stats.services_availability(time: "last_12h")
      Stats.services_availability(service_type: "grpc")
  """
  @spec services_availability(keyword()) :: Extract.services_availability()
  def services_availability(opts \\ []) do
    srql_module = Keyword.get(opts, :srql_module, default_srql_module())
    actor = Keyword.get(opts, :actor)
    query = Query.services_availability(opts)

    query
    |> srql_module.query(%{actor: actor})
    |> Extract.services_availability()
  end

  @doc """
  Fetch traces summary with computed derived values.

  Returns the base summary stats plus computed error rate and successful count.

  ## Options

  Same as `traces_summary/1`.

  ## Examples

      Stats.traces_summary_with_computed()
      # => %{
      #   total: 567,
      #   errors: 12,
      #   avg_duration_ms: 45.2,
      #   p95_duration_ms: 120.5,
      #   error_rate: 2.1,
      #   successful: 555
      # }
  """
  @spec traces_summary_with_computed(keyword()) :: map()
  def traces_summary_with_computed(opts \\ []) do
    summary = traces_summary(opts)

    summary
    |> Map.put(:error_rate, Compute.traces_error_rate(summary))
    |> Map.put(:successful, Compute.traces_successful(summary))
  end

  @doc """
  Fetch logs severity with computed percentages.

  Returns the base severity counts plus computed percentages for each level.

  ## Options

  Same as `logs_severity/1`.
  """
  @spec logs_severity_with_percentages(keyword()) :: map()
  def logs_severity_with_percentages(opts \\ []) do
    stats = logs_severity(opts)
    percentages = Compute.logs_severity_percentages(stats)
    Map.merge(stats, percentages)
  end

  # Re-export empty defaults for convenience
  defdelegate empty_logs_severity(), to: Extract
  defdelegate empty_traces_summary(), to: Extract
  defdelegate empty_services_availability(), to: Extract

  # Get the configured SRQL module
  defp default_srql_module do
    Application.get_env(:serviceradar_web_ng, :srql_module, ServiceRadarWebNG.SRQL)
  end
end
