defmodule ServiceRadar.Observability.DataRetentionWorker do
  @moduledoc """
  Recurring cleanup for high-volume observability tables that are not Timescale hypertables.
  """

  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 3,
    unique: [period: 3_600, states: :incomplete]

  alias Ecto.Adapters.SQL
  alias ServiceRadar.Inventory.EndpointInventoryRetention
  alias ServiceRadar.Inventory.EndpointInventorySettingsRuntime
  alias ServiceRadar.Repo

  require Logger

  @default_batch_size 50_000
  @default_otel_traces_retention_days 3
  @default_logs_retention_days 30
  @default_otel_metrics_retention_days 30
  @default_otel_metric_points_retention_days 30
  @default_ocsf_events_retention_days 14
  @default_ocsf_network_activity_retention_days 90
  @default_capacity_forecasts_retention_days 395
  @default_raw_metrics_retention_days 7
  @default_otel_traces_chunk_interval_hours 1
  @default_logs_chunk_interval_hours 6
  @default_otel_metrics_chunk_interval_hours 24
  @default_otel_metric_points_chunk_interval_hours 6
  @default_ocsf_events_chunk_interval_hours 6
  @default_ocsf_network_activity_chunk_interval_hours 24
  @default_capacity_forecasts_chunk_interval_hours 24
  @default_raw_metrics_chunk_interval_hours 24
  @default_trace_summary_retention_days 3
  @default_sweep_host_result_retention_days 7
  @default_sweep_execution_retention_days 30
  @default_trivy_retention_days 30
  @default_endpoint_inventory_retention_days 30
  @default_dataset_snapshot_retention_days 4
  @default_topology_link_retention_days 30
  @query_timeout_ms 120_000

  @impl Oban.Worker
  def perform(_job) do
    config = Application.get_env(:serviceradar_core, __MODULE__, [])
    batch_size = Keyword.get(config, :batch_size, @default_batch_size)

    reconcile_timescale_tables(config)

    results = [
      prune_trace_summaries(config, batch_size),
      prune_sweep_host_results(config, batch_size),
      prune_sweep_group_executions(config, batch_size),
      prune_trivy_reports(config, batch_size),
      prune_endpoint_inventory(config, batch_size),
      prune_inactive_dataset_snapshots(
        "netflow_provider_dataset_snapshots",
        config,
        batch_size
      ),
      prune_inactive_dataset_snapshots("netflow_oui_dataset_snapshots", config, batch_size),
      prune_mapper_topology_links(config, batch_size)
    ]

    deleted = Enum.sum(results)
    Logger.info("Observability data retention completed", deleted_rows: deleted)

    :ok
  end

  defp reconcile_timescale_tables(config) do
    Enum.each(
      [
        {"otel_traces", :otel_traces_retention_days, @default_otel_traces_retention_days,
         :otel_traces_chunk_interval_hours, @default_otel_traces_chunk_interval_hours},
        {"logs", :logs_retention_days, @default_logs_retention_days, :logs_chunk_interval_hours,
         @default_logs_chunk_interval_hours},
        {"otel_metrics", :otel_metrics_retention_days, @default_otel_metrics_retention_days,
         :otel_metrics_chunk_interval_hours, @default_otel_metrics_chunk_interval_hours},
        {"otel_metric_points", :otel_metric_points_retention_days,
         @default_otel_metric_points_retention_days, :otel_metric_points_chunk_interval_hours,
         @default_otel_metric_points_chunk_interval_hours},
        {"ocsf_events", :ocsf_events_retention_days, @default_ocsf_events_retention_days,
         :ocsf_events_chunk_interval_hours, @default_ocsf_events_chunk_interval_hours},
        {"ocsf_network_activity", :ocsf_network_activity_retention_days,
         @default_ocsf_network_activity_retention_days,
         :ocsf_network_activity_chunk_interval_hours,
         @default_ocsf_network_activity_chunk_interval_hours},
        {"capacity_forecasts", :capacity_forecasts_retention_days,
         @default_capacity_forecasts_retention_days, :capacity_forecasts_chunk_interval_hours,
         @default_capacity_forecasts_chunk_interval_hours},
        {"timeseries_metrics", :raw_metrics_retention_days, @default_raw_metrics_retention_days,
         :raw_metrics_chunk_interval_hours, @default_raw_metrics_chunk_interval_hours},
        {"cpu_metrics", :raw_metrics_retention_days, @default_raw_metrics_retention_days,
         :raw_metrics_chunk_interval_hours, @default_raw_metrics_chunk_interval_hours},
        {"cpu_cluster_metrics", :raw_metrics_retention_days, @default_raw_metrics_retention_days,
         :raw_metrics_chunk_interval_hours, @default_raw_metrics_chunk_interval_hours},
        {"disk_metrics", :raw_metrics_retention_days, @default_raw_metrics_retention_days,
         :raw_metrics_chunk_interval_hours, @default_raw_metrics_chunk_interval_hours},
        {"memory_metrics", :raw_metrics_retention_days, @default_raw_metrics_retention_days,
         :raw_metrics_chunk_interval_hours, @default_raw_metrics_chunk_interval_hours},
        {"process_metrics", :raw_metrics_retention_days, @default_raw_metrics_retention_days,
         :raw_metrics_chunk_interval_hours, @default_raw_metrics_chunk_interval_hours}
      ],
      fn {table_name, retention_key, retention_default, chunk_key, chunk_default} ->
        retention_days =
          config
          |> Keyword.get(retention_key, retention_default)
          |> positive_integer(retention_default)

        chunk_hours =
          config |> Keyword.get(chunk_key, chunk_default) |> positive_integer(chunk_default)

        replace_retention_policy(table_name, retention_days)
        set_chunk_interval(table_name, chunk_hours)
        drop_expired_chunks(table_name, retention_days)
      end
    )
  end

  defp replace_retention_policy(table_name, retention_days) do
    sql = """
    DO $$
    DECLARE
      table_ident text;
      ts_schema text;
    BEGIN
      table_ident := format('%I.%I', 'platform', '#{table_name}');

      SELECT n.nspname
      INTO ts_schema
      FROM pg_extension e
      JOIN pg_namespace n ON n.oid = e.extnamespace
      WHERE e.extname = 'timescaledb';

      IF ts_schema IS NOT NULL
         AND EXISTS (
           SELECT 1
           FROM timescaledb_information.hypertables
           WHERE hypertable_schema = 'platform'
             AND hypertable_name = '#{table_name}'
         ) THEN
        EXECUTE format(
          'SELECT %I.remove_retention_policy(%L::regclass, if_exists => true)',
          ts_schema,
          table_ident
        );

        EXECUTE format(
          'SELECT %I.add_retention_policy(%L::regclass, INTERVAL ''#{retention_days} days'', if_not_exists => true)',
          ts_schema,
          table_ident
        );
      END IF;
    EXCEPTION
      WHEN others THEN
        RAISE NOTICE 'Could not reconcile retention policy for #{table_name}: %', SQLERRM;
    END;
    $$;
    """

    case SQL.query(Repo, sql, [], timeout: @query_timeout_ms) do
      {:ok, _result} ->
        :ok

      {:error, error} ->
        Logger.warning("Failed to reconcile Timescale retention policy",
          table: table_name,
          retention_days: retention_days,
          reason: Exception.message(error)
        )
    end
  end

  defp set_chunk_interval(table_name, chunk_hours) do
    sql = """
    DO $$
    DECLARE
      table_ident text;
      ts_schema text;
    BEGIN
      table_ident := format('%I.%I', 'platform', '#{table_name}');

      SELECT n.nspname
      INTO ts_schema
      FROM pg_extension e
      JOIN pg_namespace n ON n.oid = e.extnamespace
      WHERE e.extname = 'timescaledb';

      IF ts_schema IS NOT NULL
         AND EXISTS (
           SELECT 1
           FROM timescaledb_information.hypertables
           WHERE hypertable_schema = 'platform'
             AND hypertable_name = '#{table_name}'
         ) THEN
        EXECUTE format(
          'SELECT %I.set_chunk_time_interval(%L::regclass, INTERVAL ''#{chunk_hours} hours'')',
          ts_schema,
          table_ident
        );
      END IF;
    EXCEPTION
      WHEN others THEN
        RAISE NOTICE 'Could not reconcile chunk interval for #{table_name}: %', SQLERRM;
    END;
    $$;
    """

    case SQL.query(Repo, sql, [], timeout: @query_timeout_ms) do
      {:ok, _result} ->
        :ok

      {:error, error} ->
        Logger.warning("Failed to reconcile Timescale chunk interval",
          table: table_name,
          chunk_hours: chunk_hours,
          reason: Exception.message(error)
        )
    end
  end

  defp drop_expired_chunks(table_name, retention_days) do
    sql = """
    DO $$
    DECLARE
      table_ident text;
      ts_schema text;
    BEGIN
      table_ident := format('%I.%I', 'platform', '#{table_name}');

      SELECT n.nspname
      INTO ts_schema
      FROM pg_extension e
      JOIN pg_namespace n ON n.oid = e.extnamespace
      WHERE e.extname = 'timescaledb';

      IF ts_schema IS NOT NULL
         AND EXISTS (
           SELECT 1
           FROM timescaledb_information.hypertables
           WHERE hypertable_schema = 'platform'
             AND hypertable_name = '#{table_name}'
         ) THEN
        EXECUTE format(
          'SELECT %I.drop_chunks(%L::regclass, older_than => INTERVAL ''#{retention_days} days'')',
          ts_schema,
          table_ident
        );
      END IF;
    EXCEPTION
      WHEN others THEN
        RAISE NOTICE 'Could not drop expired chunks for #{table_name}: %', SQLERRM;
    END;
    $$;
    """

    case SQL.query(Repo, sql, [], timeout: @query_timeout_ms) do
      {:ok, _result} ->
        :ok

      {:error, error} ->
        Logger.warning("Failed to drop expired Timescale chunks",
          table: table_name,
          retention_days: retention_days,
          reason: Exception.message(error)
        )
    end
  end

  defp prune_trace_summaries(config, batch_size) do
    retention_days =
      Keyword.get(config, :trace_summary_retention_days, @default_trace_summary_retention_days)

    prune_by_timestamp(
      "otel_trace_summaries",
      "trace_id",
      "timestamp",
      retention_days,
      batch_size
    )
  end

  defp prune_sweep_host_results(config, batch_size) do
    retention_days =
      Keyword.get(
        config,
        :sweep_host_result_retention_days,
        @default_sweep_host_result_retention_days
      )

    prune_by_timestamp(
      "sweep_host_results",
      "id",
      "inserted_at",
      retention_days,
      batch_size
    )
  end

  defp prune_sweep_group_executions(config, batch_size) do
    retention_days =
      Keyword.get(
        config,
        :sweep_execution_retention_days,
        @default_sweep_execution_retention_days
      )

    prune_by_timestamp(
      "sweep_group_executions",
      "id",
      "started_at",
      retention_days,
      batch_size,
      "AND status IN ('completed', 'failed')"
    )
  end

  defp prune_trivy_reports(config, batch_size) do
    retention_days = Keyword.get(config, :trivy_retention_days, @default_trivy_retention_days)

    prune_by_timestamp(
      "trivy_reports",
      "event_uuid",
      "observed_at",
      retention_days,
      batch_size
    )
  end

  defp prune_endpoint_inventory(config, batch_size) do
    retention_days =
      config
      |> Keyword.get(
        :endpoint_inventory_retention_days,
        @default_endpoint_inventory_retention_days
      )
      |> EndpointInventorySettingsRuntime.retention_days()

    case EndpointInventoryRetention.prune(
           retention_days: retention_days,
           batch_size: batch_size,
           timeout: Keyword.get(config, :endpoint_inventory_datasvc_timeout_ms, 30_000)
         ) do
      {:ok, %{deleted_scans: deleted}} ->
        deleted

      {:error, error} ->
        Logger.warning("Failed to prune retained endpoint inventory data",
          reason: Exception.message(error)
        )

        0
    end
  end

  defp prune_inactive_dataset_snapshots(table_name, config, batch_size) do
    retention_days =
      Keyword.get(
        config,
        :dataset_snapshot_retention_days,
        @default_dataset_snapshot_retention_days
      )

    prune_by_timestamp(
      table_name,
      "id",
      "fetched_at",
      retention_days,
      batch_size,
      "AND is_active = FALSE"
    )
  end

  defp prune_mapper_topology_links(config, batch_size) do
    retention_days =
      Keyword.get(
        config,
        :topology_link_retention_days,
        @default_topology_link_retention_days
      )

    prune_by_timestamp(
      "mapper_topology_links",
      "id",
      "timestamp",
      retention_days,
      batch_size
    )
  end

  defp prune_by_timestamp(
         table_name,
         key_column,
         timestamp_column,
         retention_days,
         batch_size,
         extra_where \\ ""
       ) do
    sql = """
    WITH doomed AS (
      SELECT #{key_column}
      FROM platform.#{table_name}
      WHERE #{timestamp_column} < NOW() - ($1::int * INTERVAL '1 day')
      #{extra_where}
      ORDER BY #{timestamp_column} ASC
      LIMIT $2
    )
    DELETE FROM platform.#{table_name} AS target
    USING doomed
    WHERE target.#{key_column} = doomed.#{key_column}
    """

    case SQL.query(Repo, sql, [retention_days, batch_size], timeout: @query_timeout_ms) do
      {:ok, %{num_rows: deleted}} ->
        if deleted > 0 do
          Logger.info("Pruned retained observability data",
            table: table_name,
            deleted_rows: deleted,
            retention_days: retention_days
          )
        end

        deleted

      {:error, %Postgrex.Error{postgres: %{code: :undefined_table}}} ->
        0

      {:error, error} ->
        Logger.warning("Failed to prune retained observability data",
          table: table_name,
          reason: Exception.message(error)
        )

        0
    end
  end

  defp positive_integer(value, _default) when is_integer(value) and value > 0, do: value
  defp positive_integer(_value, default), do: default
end
