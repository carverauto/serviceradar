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

  import Ecto.Query

  alias ServiceRadarWebNG.Repo
  alias ServiceRadarWebNGWeb.Stats.{Query, Extract, Compute}

  @type alerts_summary :: %{
          total: non_neg_integer(),
          pending: non_neg_integer(),
          acknowledged: non_neg_integer(),
          resolved: non_neg_integer(),
          escalated: non_neg_integer(),
          suppressed: non_neg_integer()
        }

  @type events_summary :: %{
          total: non_neg_integer(),
          fatal: non_neg_integer(),
          critical: non_neg_integer(),
          high: non_neg_integer(),
          medium: non_neg_integer(),
          low: non_neg_integer(),
          informational: non_neg_integer()
        }

  @doc """
  Fetch logs severity stats using the rollup_stats pattern.

  Returns aggregated counts by severity level from the pre-computed CAGG.

  ## Options

    * `:time` - Time range filter (default: "last_24h")
    * `:service_name` - Filter by service name (optional)
    * `:source` - Filter by log source (optional)
    * `:srql_module` - SRQL module to use (default from config)

  ## Examples

      Stats.logs_severity()
      Stats.logs_severity(time: "last_1h")
      Stats.logs_severity(service_name: "api-gateway")
  """
  @spec logs_severity(keyword()) :: Extract.logs_severity()
  def logs_severity(opts \\ []) do
    srql_module = Keyword.get(opts, :srql_module, default_srql_module())
    scope = Keyword.get(opts, :scope)
    query = Query.logs_severity(opts)

    query
    |> srql_module.query(%{scope: scope})
    |> Extract.logs_severity()
  end

  @doc """
  Fetch overall alert status counts from the alerts table.

  This summary intentionally ignores pagination so alert overview cards reflect
  the full retained alert set rather than the currently visible page slice.
  """
  @spec alerts_summary(keyword()) :: alerts_summary()
  def alerts_summary(_opts \\ []) do
    query =
      from(a in "alerts",
        select: %{
          total: count(),
          pending: fragment("COUNT(*) FILTER (WHERE ? = 'pending')", a.status),
          acknowledged: fragment("COUNT(*) FILTER (WHERE ? = 'acknowledged')", a.status),
          resolved: fragment("COUNT(*) FILTER (WHERE ? = 'resolved')", a.status),
          escalated: fragment("COUNT(*) FILTER (WHERE ? = 'escalated')", a.status),
          suppressed: fragment("COUNT(*) FILTER (WHERE ? = 'suppressed')", a.status)
        }
      )

    case Repo.one(query) do
      %{total: _} = summary ->
        %{
          total: to_int(summary.total),
          pending: to_int(summary.pending),
          acknowledged: to_int(summary.acknowledged),
          resolved: to_int(summary.resolved),
          escalated: to_int(summary.escalated),
          suppressed: to_int(summary.suppressed)
        }

      _ ->
        empty_alerts_summary()
    end
  rescue
    _ -> empty_alerts_summary()
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
    scope = Keyword.get(opts, :scope)
    query = Query.traces_summary(opts)

    query
    |> srql_module.query(%{scope: scope})
    |> Extract.traces_summary()
  end

  @doc """
  Fetch event severity counts from the hourly OCSF events aggregate.

  This summary intentionally ignores pagination so overview cards reflect the
  selected time window rather than the currently visible page slice.
  """
  @spec events_summary(keyword()) :: events_summary()
  def events_summary(opts \\ []) do
    time_window = Keyword.get(opts, :time, "last_7d")

    case cutoff_for_time_window(time_window) do
      {:ok, cutoff} ->
        query =
          from(s in "ocsf_events_hourly_stats",
            where: s.bucket >= ^cutoff,
            group_by: s.severity_id,
            select: {s.severity_id, sum(s.total_count)}
          )

        query
        |> Repo.all()
        |> merge_event_stats(empty_events_summary())

      _ ->
        empty_events_summary()
    end
  rescue
    _ -> empty_events_summary()
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
    scope = Keyword.get(opts, :scope)
    query = Query.services_availability(opts)

    query
    |> srql_module.query(%{scope: scope})
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

  @spec empty_alerts_summary() :: alerts_summary()
  def empty_alerts_summary do
    %{total: 0, pending: 0, acknowledged: 0, resolved: 0, escalated: 0, suppressed: 0}
  end

  @spec empty_events_summary() :: events_summary()
  def empty_events_summary do
    %{total: 0, fatal: 0, critical: 0, high: 0, medium: 0, low: 0, informational: 0}
  end

  # Get the configured SRQL module
  defp default_srql_module do
    Application.get_env(:serviceradar_web_ng, :srql_module, ServiceRadarWebNG.SRQL)
  end

  defp merge_event_stats(rows, base) when is_list(rows) do
    Enum.reduce(rows, base, fn {severity_id, total_count}, acc ->
      count = to_int(total_count)
      acc = Map.update!(acc, :total, &(&1 + count))

      case to_int(severity_id) do
        6 -> Map.update!(acc, :fatal, &(&1 + count))
        5 -> Map.update!(acc, :critical, &(&1 + count))
        4 -> Map.update!(acc, :high, &(&1 + count))
        3 -> Map.update!(acc, :medium, &(&1 + count))
        2 -> Map.update!(acc, :low, &(&1 + count))
        1 -> Map.update!(acc, :informational, &(&1 + count))
        _ -> acc
      end
    end)
  end

  defp merge_event_stats(_, base), do: base

  defp cutoff_for_time_window("last_1h"), do: {:ok, DateTime.add(DateTime.utc_now(), -1, :hour)}
  defp cutoff_for_time_window("last_24h"), do: {:ok, DateTime.add(DateTime.utc_now(), -24, :hour)}

  defp cutoff_for_time_window(value) when is_binary(value) do
    case Regex.run(~r/^last_(\d+)([hd])$/i, String.trim(value)) do
      [_, amount, "h"] ->
        {:ok, DateTime.add(DateTime.utc_now(), -String.to_integer(amount), :hour)}

      [_, amount, "d"] ->
        {:ok, DateTime.add(DateTime.utc_now(), -String.to_integer(amount), :day)}

      _ ->
        :error
    end
  end

  defp cutoff_for_time_window(_), do: :error

  defp to_int(value) when is_integer(value), do: value
  defp to_int(value) when is_float(value), do: trunc(value)
  defp to_int(%Decimal{} = value), do: Decimal.to_integer(value)

  defp to_int(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} -> parsed
      {parsed, _} -> parsed
      :error -> 0
    end
  end

  defp to_int(_), do: 0
end
