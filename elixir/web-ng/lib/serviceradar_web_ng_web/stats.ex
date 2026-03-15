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

  alias Ecto.Adapters.SQL
  alias ServiceRadarWebNG.Repo
  alias ServiceRadarWebNGWeb.Stats.Compute
  alias ServiceRadarWebNGWeb.Stats.Extract
  alias ServiceRadarWebNGWeb.Stats.Query

  require Logger

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

  @type trace_rollup_status :: %{
          healthy?: boolean(),
          summary_table_present?: boolean(),
          traces_rollup_present?: boolean(),
          raw_latest_timestamp: DateTime.t() | nil,
          summary_latest_timestamp: DateTime.t() | nil,
          rollup_latest_bucket: DateTime.t() | nil,
          summary_lag_seconds: non_neg_integer() | nil,
          rollup_lag_seconds: non_neg_integer() | nil,
          messages: [String.t()]
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

  @doc """
  Check whether the trace summary table and trace rollup backing the UI are
  present and reasonably fresh compared to raw trace ingest.
  """
  @spec trace_rollup_status(keyword()) :: trace_rollup_status()
  def trace_rollup_status(opts \\ []) do
    if repo_started?() do
      do_trace_rollup_status(opts)
    else
      empty_trace_rollup_status()
    end
  end

  defp do_trace_rollup_status(opts) do
    threshold_seconds =
      Keyword.get(opts, :stale_threshold_seconds, trace_rollup_stale_threshold_seconds())

    summary_table_present? = relation_exists?("platform.otel_trace_summaries")
    traces_rollup_present? = traces_rollup_exists?()
    raw_latest_timestamp = raw_traces_latest_timestamp()

    summary_latest_timestamp =
      if summary_table_present? do
        trace_summaries_latest_timestamp()
      end

    rollup_latest_bucket =
      if traces_rollup_present? do
        traces_rollup_latest_bucket()
      end

    assess_trace_rollup_status(
      summary_table_present?: summary_table_present?,
      traces_rollup_present?: traces_rollup_present?,
      raw_latest_timestamp: raw_latest_timestamp,
      summary_latest_timestamp: summary_latest_timestamp,
      rollup_latest_bucket: rollup_latest_bucket,
      stale_threshold_seconds: threshold_seconds
    )
  rescue
    error ->
      Logger.warning("trace rollup health verification failed: #{Exception.message(error)}")

      empty_trace_rollup_status()
  end

  @doc false
  @spec assess_trace_rollup_status(keyword()) :: trace_rollup_status()
  def assess_trace_rollup_status(opts) do
    summary_table_present? = Keyword.get(opts, :summary_table_present?, false)
    traces_rollup_present? = Keyword.get(opts, :traces_rollup_present?, false)
    raw_latest_timestamp = Keyword.get(opts, :raw_latest_timestamp)
    summary_latest_timestamp = Keyword.get(opts, :summary_latest_timestamp)
    rollup_latest_bucket = Keyword.get(opts, :rollup_latest_bucket)
    stale_threshold_seconds = Keyword.get(opts, :stale_threshold_seconds, 1800)

    summary_lag_seconds = lag_seconds(raw_latest_timestamp, summary_latest_timestamp)
    rollup_lag_seconds = lag_seconds(raw_latest_timestamp, rollup_latest_bucket)

    messages =
      []
      |> maybe_add_message(
        not summary_table_present?,
        "Missing trace summary table: platform.otel_trace_summaries."
      )
      |> maybe_add_message(
        not traces_rollup_present?,
        "Missing trace rollup: platform.traces_stats_5m continuous aggregate."
      )
      |> maybe_add_message(
        raw_latest_timestamp && summary_table_present? && is_nil(summary_latest_timestamp),
        "Trace summaries are empty while raw traces exist."
      )
      |> maybe_add_message(
        raw_latest_timestamp && traces_rollup_present? && is_nil(rollup_latest_bucket),
        "Trace rollup is empty while raw traces exist."
      )
      |> maybe_add_message(
        stale?(summary_lag_seconds, stale_threshold_seconds),
        "Trace summaries lag raw traces by #{format_lag(summary_lag_seconds)}."
      )
      |> maybe_add_message(
        stale?(rollup_lag_seconds, stale_threshold_seconds),
        "Trace rollup lags raw traces by #{format_lag(rollup_lag_seconds)}."
      )

    %{
      healthy?: messages == [],
      summary_table_present?: summary_table_present?,
      traces_rollup_present?: traces_rollup_present?,
      raw_latest_timestamp: raw_latest_timestamp,
      summary_latest_timestamp: summary_latest_timestamp,
      rollup_latest_bucket: rollup_latest_bucket,
      summary_lag_seconds: summary_lag_seconds,
      rollup_lag_seconds: rollup_lag_seconds,
      messages: messages
    }
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

  @spec empty_trace_rollup_status() :: trace_rollup_status()
  def empty_trace_rollup_status do
    %{
      healthy?: true,
      summary_table_present?: true,
      traces_rollup_present?: true,
      raw_latest_timestamp: nil,
      summary_latest_timestamp: nil,
      rollup_latest_bucket: nil,
      summary_lag_seconds: nil,
      rollup_lag_seconds: nil,
      messages: []
    }
  end

  # Get the configured SRQL module
  defp default_srql_module do
    Application.get_env(:serviceradar_web_ng, :srql_module, ServiceRadarWebNG.SRQL)
  end

  defp relation_exists?(relation_name) when is_binary(relation_name) do
    case SQL.query(Repo, "SELECT to_regclass($1) IS NOT NULL", [relation_name]) do
      {:ok, %{rows: [[value]]}} -> value == true
      _ -> false
    end
  end

  defp repo_started?, do: is_pid(Process.whereis(Repo))

  defp traces_rollup_exists? do
    case SQL.query(
           Repo,
           """
           SELECT EXISTS(
             SELECT 1
             FROM timescaledb_information.continuous_aggregates
             WHERE view_schema = 'platform' AND view_name = 'traces_stats_5m'
           )
           """,
           []
         ) do
      {:ok, %{rows: [[value]]}} -> value == true
      _ -> false
    end
  end

  defp raw_traces_latest_timestamp do
    case SQL.query(Repo, "SELECT max(timestamp) FROM otel_traces", []) do
      {:ok, %{rows: [[value]]}} -> normalize_datetime(value)
      _ -> nil
    end
  end

  defp trace_summaries_latest_timestamp do
    case SQL.query(Repo, "SELECT max(timestamp) FROM otel_trace_summaries", []) do
      {:ok, %{rows: [[value]]}} -> normalize_datetime(value)
      _ -> nil
    end
  end

  defp traces_rollup_latest_bucket do
    case SQL.query(Repo, "SELECT max(bucket) FROM traces_stats_5m", []) do
      {:ok, %{rows: [[value]]}} -> normalize_datetime(value)
      _ -> nil
    end
  end

  defp normalize_datetime(%DateTime{} = value), do: value
  defp normalize_datetime(%NaiveDateTime{} = value), do: DateTime.from_naive!(value, "Etc/UTC")
  defp normalize_datetime(_), do: nil

  defp lag_seconds(%DateTime{} = newer, %DateTime{} = older) do
    max(DateTime.diff(newer, older, :second), 0)
  end

  defp lag_seconds(_, _), do: nil

  defp trace_rollup_stale_threshold_seconds do
    Application.get_env(:serviceradar_web_ng, :trace_rollup_stale_threshold_seconds, 30 * 60)
  end

  defp stale?(lag_seconds, threshold_seconds) when is_integer(lag_seconds) and is_integer(threshold_seconds) do
    lag_seconds > threshold_seconds
  end

  defp stale?(_, _), do: false

  defp maybe_add_message(messages, true, message) when is_binary(message), do: messages ++ [message]

  defp maybe_add_message(messages, _, _), do: messages

  defp format_lag(seconds) when is_integer(seconds) and seconds >= 3600 do
    hours = div(seconds, 3600)
    minutes = div(rem(seconds, 3600), 60)
    "#{hours}h #{minutes}m"
  end

  defp format_lag(seconds) when is_integer(seconds) and seconds >= 60 do
    minutes = div(seconds, 60)
    rem_seconds = rem(seconds, 60)
    "#{minutes}m #{rem_seconds}s"
  end

  defp format_lag(seconds) when is_integer(seconds), do: "#{seconds}s"
  defp format_lag(_), do: "unknown"

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
