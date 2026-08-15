defmodule ServiceRadar.Observability.DataRetentionWorker do
  @moduledoc """
  Recurring cleanup for high-volume observability tables that are not Timescale hypertables.
  """

  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 3,
    unique: [period: 3_600, states: :incomplete]

  alias Ecto.Adapters.SQL
  alias ServiceRadar.ColdTier.Config
  alias ServiceRadar.ColdTier.RetentionFence
  alias ServiceRadar.Inventory.EndpointInventoryRetention
  alias ServiceRadar.Inventory.EndpointInventorySettingsRuntime
  alias ServiceRadar.Observability.DatasetSnapshotPrune
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
  @default_timeseries_metrics_retention_days 7
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
  @default_dataset_snapshot_retention_days 2
  @default_dataset_snapshot_keep_last 1
  @default_topology_link_retention_days 30
  @query_timeout_ms 120_000

  @impl Oban.Worker
  def perform(_job) do
    config = Application.get_env(:serviceradar_core, __MODULE__, [])
    batch_size = Keyword.get(config, :batch_size, @default_batch_size)

    reconcile_timescale_tables(config)
    # Widening rollup retention costs storage on every deployment and only pays
    # for itself once raw history is served from the cold tier, so it follows
    # the enable flag from here instead of being a one-way migration. Returns
    # immediately without querying when the cold tier is not enabled.
    RetentionFence.reconcile_cagg_windows()
    alert_on_cagg_refresh_hazards()
    alert_on_undrained_cold_tier()
    alert_on_misconfigured_cold_tier()

    results = [
      prune_trace_summaries(config, batch_size),
      prune_sweep_host_results(config, batch_size),
      prune_sweep_group_executions(config, batch_size),
      prune_trivy_reports(config, batch_size),
      prune_endpoint_inventory(config, batch_size),
      prune_dataset_snapshots(
        "netflow_provider_dataset_snapshots",
        "netflow_provider_cidrs",
        config,
        batch_size
      ),
      prune_dataset_snapshots(
        "netflow_oui_dataset_snapshots",
        "netflow_oui_prefixes",
        config,
        batch_size
      ),
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
        {"timeseries_metrics", :timeseries_metrics_retention_days,
         @default_timeseries_metrics_retention_days, :raw_metrics_chunk_interval_hours,
         @default_raw_metrics_chunk_interval_hours},
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

        # All in-DB policy DDL goes through the cold-tier fence: unfenced
        # tables keep today's remove+add behavior; fenced (offloaded) tables
        # get their in-DB policy removed so only the gated drop below can
        # ever discard data.
        RetentionFence.reconcile_policy(table_name, retention_days)
        set_chunk_interval(table_name, chunk_hours)
        drop_expired_chunks(table_name, retention_days)
      end
    )
  end

  defp alert_on_undrained_cold_tier do
    case RetentionFence.undrained_tables() do
      [] ->
        :ok

      tables ->
        Logger.error(
          "Cold tier is DISABLED but un-drained state remains — retention stays " <>
            "fenced (only verified-exported data drops) until an operator completes " <>
            "the disable with ServiceRadar.ColdTier.Admin.waive/2",
          tables: tables
        )
    end
  end

  # The cold tier is intended (enable flag + bucket) but the config is
  # incomplete, so the exporter/pruner cannot run (review F09). The fence
  # deliberately does NOT engage in this state — normal retention proceeds so
  # the primary cannot fill behind a dead exporter — but this must be loud,
  # because the operator believes offload is happening and it is not.
  defp alert_on_misconfigured_cold_tier do
    if Config.state() == :misconfigured do
      Logger.error(
        "Cold tier is INTENDED but MISCONFIGURED — offload is NOT running and data " <>
          "aging past hot retention is being dropped by normal retention, not archived. " <>
          "Supply the missing configuration.",
        missing: Config.misconfiguration_reasons()
      )
    end
  end

  # A CAGG that refreshes past its raw source's retention DELETES its own
  # materialized history when the policy refresh covers a dropped-chunk
  # region (drop_chunks plants invalidations; verified on TimescaleDB
  # 2.24.0). Migration 20260716210000 clamps the shipped policies; this
  # guard catches per-deployment drift (env-tuned retention windows or
  # hand-created policies).
  defp alert_on_cagg_refresh_hazards do
    case RetentionFence.cagg_refresh_hazards() do
      [] ->
        :ok

      hazards ->
        Logger.error(
          "Continuous aggregates refresh past their raw source's retention — " <>
            "policy refreshes will progressively DELETE materialized history " <>
            "for dropped regions; clamp start_offset below the source retention",
          hazards: inspect(hazards)
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
    # Fence-gated: on cold-configured deployments the drop point for registry
    # tables is bounded by the acked query boundary and the contiguous
    # verified-export prefix; :hold means data is retained (never silently
    # lost) until exports catch up. Unfenced tables get the plain retention
    # cutoff — identical to the previous interval-based behavior.
    #
    # The gate computation and the drop run inside ONE transaction holding the
    # per-table cold-tier lock (review F02), so the exporter cannot flip a
    # chunk's manifest status between the gate's checks and the drop.
    RetentionFence.with_table_lock(table_name, fn ->
      case RetentionFence.safe_drop_point(table_name, retention_days) do
        {:ok, drop_point} ->
          drop_chunks_older_than(table_name, drop_point)

        :hold ->
          Logger.info("Cold tier is holding expired chunks pending verified export",
            table: table_name,
            retention_days: retention_days
          )

          :ok
      end
    end)
  end

  defp drop_chunks_older_than(table_name, %DateTime{} = drop_point) do
    cutoff = drop_point |> DateTime.truncate(:second) |> DateTime.to_iso8601()

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
          'SELECT %I.drop_chunks(%L::regclass, older_than => TIMESTAMPTZ ''#{cutoff}'')',
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
          drop_point: cutoff,
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

  defp prune_dataset_snapshots(snapshot_table, entry_table, config, batch_size) do
    case DatasetSnapshotPrune.run(snapshot_table, entry_table,
           retention_days:
             Keyword.get(
               config,
               :dataset_snapshot_retention_days,
               @default_dataset_snapshot_retention_days
             ),
           keep_last:
             Keyword.get(
               config,
               :dataset_snapshot_keep_last,
               @default_dataset_snapshot_keep_last
             ),
           entry_batch_size: batch_size
         ) do
      {:ok, %{deleted_snapshots: snapshots, deleted_entries: entries}} ->
        snapshots + entries

      {:error, reason} ->
        Logger.warning("Failed to prune retained dataset snapshots",
          table: snapshot_table,
          reason: inspect(reason)
        )

        0
    end
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
