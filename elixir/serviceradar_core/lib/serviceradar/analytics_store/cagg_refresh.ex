defmodule ServiceRadar.AnalyticsStore.CaggRefresh do
  @moduledoc """
  Stop Timescale CAGG refresh on tables that have flipped to pg_duckdb.

  Dual-write keeps the hypertable as the store, so CAGGs keep refreshing.
  Hybrid restores missing timeseries refresh policies after a pg_duckdb flip.
  After a table flips, EventWriter no longer inserts there: refresh would
  scan an abandoned hypertable and serve stale buckets. Views stay in place
  for rollback. SRQL's duckdb dialect aggregates over Parquet (task 4.3).

  cpu/memory/disk/process hourly CAGGs stay on Timescale until those
  hypertables are in the analytics-store registry and flipped. Dual-running
  CAGGs and Parquet rollups after a flip is a non-goal (design D7).
  """

  alias Ecto.Adapters.SQL
  alias ServiceRadar.AnalyticsStore.Config
  alias ServiceRadar.Repo

  require Logger

  @query_timeout_ms 60_000

  # Source table → CAGG views that refresh from it. Keep in lockstep with
  # rust/srql/src/query/cagg.rs plus the flow/log/trace rollup views.
  @caggs %{
    "timeseries_metrics" => [
      "timeseries_metrics_hourly",
      "timeseries_metrics_interface_hourly",
      "timeseries_metrics_disk_hourly"
    ],
    "ocsf_network_activity" => [
      "ocsf_network_activity_5m_traffic",
      "ocsf_network_activity_hourly_proto",
      "ocsf_network_activity_hourly_talkers",
      "ocsf_network_activity_hourly_ports",
      "ocsf_network_activity_hourly_listeners",
      "ocsf_network_activity_hourly_conversations"
    ],
    "logs" => ["logs_severity_stats_5m"],
    "ocsf_events" => ["ocsf_events_hourly_stats"],
    "otel_metrics" => ["otel_metrics_hourly_stats"],
    "otel_traces" => ["traces_stats_5m", "spans_red_1h"],
    "cpu_metrics" => ["cpu_metrics_hourly"],
    "memory_metrics" => ["memory_metrics_hourly"],
    "disk_metrics" => ["disk_metrics_hourly"],
    "process_metrics" => ["process_metrics_hourly"]
  }

  @doc "CAGG view names that refresh from `table`."
  @spec views_for(String.t()) :: [String.t()]
  def views_for(table) when is_binary(table), do: Map.get(@caggs, table, [])

  @doc "SQL that removes a CAGG refresh policy if one is installed."
  @spec remove_policy_sql(String.t()) :: String.t()
  def remove_policy_sql(view) when is_binary(view) do
    if !valid_ident?(view) do
      raise ArgumentError, "invalid CAGG view name: #{inspect(view)}"
    end

    """
    DO $$
    DECLARE
      ts_schema text;
    BEGIN
      SELECT n.nspname INTO ts_schema
        FROM pg_extension e
        JOIN pg_namespace n ON n.oid = e.extnamespace
       WHERE e.extname = 'timescaledb';
      IF ts_schema IS NOT NULL THEN
        EXECUTE format(
          'SELECT %I.remove_continuous_aggregate_policy(%L::regclass, if_exists => true)',
          ts_schema,
          format('%I.%I', 'platform', '#{view}')
        );
      END IF;
    EXCEPTION WHEN others THEN
      RAISE NOTICE 'Could not remove CAGG policy for #{view}: %', SQLERRM;
    END;
    $$;
    """
  end

  @doc "Restore a missing timeseries refresh policy without replacing an operator's policy."
  @spec restore_policy_sql(String.t(), pos_integer()) :: String.t()
  def restore_policy_sql(view, hot_window_days)
      when is_binary(view) and is_integer(hot_window_days) and hot_window_days > 0 do
    if view not in views_for("timeseries_metrics") do
      raise ArgumentError, "unsupported timeseries CAGG view: #{inspect(view)}"
    end

    # Preserve the shipped five-day refresh window where possible, with a
    # margin before raw retention so refresh never erases dropped history.
    start_hours = min(120, max(1, (hot_window_days - 1) * 24))

    """
    DO $$
    DECLARE
      ts_schema text;
    BEGIN
      SELECT n.nspname INTO ts_schema
        FROM pg_extension e
        JOIN pg_namespace n ON n.oid = e.extnamespace
       WHERE e.extname = 'timescaledb';
      IF ts_schema IS NULL THEN
        RETURN;
      END IF;
      IF NOT EXISTS (
        SELECT 1 FROM timescaledb_information.continuous_aggregates
         WHERE view_schema = 'platform' AND view_name = '#{view}'
      ) THEN
        RETURN;
      END IF;
      EXECUTE format(
        'SELECT %I.add_continuous_aggregate_policy(%L::regclass, '
        'start_offset => INTERVAL ''#{start_hours} hours'', '
        'end_offset => INTERVAL ''10 minutes'', '
        'schedule_interval => INTERVAL ''10 minutes'', if_not_exists => true)',
        ts_schema,
        format('%I.%I', 'platform', '#{view}')
      );
    END;
    $$;
    """
  end

  @doc "Stop pure pg_duckdb refresh and restore missing hybrid timeseries refresh policies."
  @spec reconcile(keyword()) :: :ok
  def reconcile(opts \\ []) do
    cfg = Keyword.get_lazy(opts, :config, &Config.load/0)
    exec = Keyword.get(opts, :exec, &default_exec/1)

    cfg
    |> Config.flipped_tables()
    |> Enum.each(fn entry ->
      Enum.each(views_for(entry.table), fn view ->
        exec.(remove_policy_sql(view))

        Logger.info("analytics store: stopped CAGG refresh for flipped table",
          table: entry.table,
          view: view
        )
      end)
    end)

    if Config.driver_for(cfg, "timeseries_metrics") == :hybrid do
      Enum.each(views_for("timeseries_metrics"), fn view ->
        exec.(restore_policy_sql(view, cfg.hot_window_days))
      end)
    end

    :ok
  end

  defp valid_ident?(name), do: name =~ ~r/^[a-z][a-z0-9_]*$/

  defp default_exec(sql) do
    case SQL.query(Repo, sql, [], timeout: @query_timeout_ms) do
      {:ok, _} ->
        :ok

      {:error, error} ->
        Logger.warning("CAGG policy reconciliation failed", reason: Exception.message(error))
    end
  end
end
