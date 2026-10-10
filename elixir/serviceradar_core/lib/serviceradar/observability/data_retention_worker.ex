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
  alias ServiceRadar.Observability.SeasonalDisposition.StateStore
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
  # Raw timeseries_metrics is the largest table and its 24-hour chunks are
  # only small once compressed, so the lag before compression sets the disk
  # footprint. 24 hours keeps the open chunk plus at most one closed chunk raw.
  @default_timeseries_metrics_compress_after_hours 24
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
  @default_hourly_rollup_retention_days 395
  # The hourly rollups refresh the last 5 days from raw (migration
  # 20260716210000). Retention inside that window would re-materialize dropped
  # buckets, and TimescaleDB rejects a compression policy that overlaps it, so
  # both stay at 7 days: the raw source's own retention.
  @min_hourly_rollup_retention_days 7
  @hourly_rollup_compress_after_days 7
  # Retention drops whole chunks, so the chunk interval bounds how long data
  # outlives its retention window. The rollups were created with a 70-day
  # interval, which let a 7-day policy keep ten weeks of rows.
  @hourly_rollup_chunk_interval_hours 24
  @hourly_rollups ~w(
    cpu_metrics_hourly
    memory_metrics_hourly
    disk_metrics_hourly
    process_metrics_hourly
    timeseries_metrics_hourly
    timeseries_metrics_disk_hourly
    timeseries_metrics_interface_hourly
  )
  @query_timeout_ms 120_000

  @impl Oban.Worker
  def perform(_job) do
    config = Application.get_env(:serviceradar_core, __MODULE__, [])
    batch_size = Keyword.get(config, :batch_size, @default_batch_size)

    reconcile_timescale_tables(config)
    reconcile_timeseries_metrics_compression(config)
    reconcile_hourly_rollups(config)
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
      prune_endpoint_inventory(config),
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
      prune_mapper_topology_links(config, batch_size),
      prune_seasonal_disposition_states(config, batch_size)
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
    if Config.intended?() and Config.warehouse_backend?() do
      ServiceRadar.ColdTier.Health.record_backend()

      Logger.warning(
        "Cold tier does NOT archive StarRocks telemetry; configured exports cover only " <>
          "CNPG history. Existing CNPG retention fences remain in force until history " <>
          "is verified or explicitly waived.",
        tables: ServiceRadar.ColdTier.Registry.table_names(),
        cnpg_export_enabled: Config.enabled?()
      )
    end

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

  @doc """
  Reconcile the compression policy on raw `platform.timeseries_metrics` to the
  configured lag (`:timeseries_metrics_compress_after_hours`).

  Migration `20261006160000` enables compression and installs the policy, but
  with a fixed 6-day lag, and an existing policy keeps whatever lag it was
  created with. At sweep volume six raw days outgrow the CNPG volume, so the
  lag is configuration. Compressing a raw chunk does not stop the hourly
  rollups from refreshing over it.

  The policy is re-registered only when the lag changed, because
  `add_compression_policy` resets the job schedule. A database without
  TimescaleDB, or a table without compression enabled, is skipped.
  """
  @spec reconcile_timeseries_metrics_compression(keyword()) :: :ok
  def reconcile_timeseries_metrics_compression(config) do
    compress_after_hours = timeseries_metrics_compress_after_hours(config)

    case SQL.query(Repo, timeseries_metrics_compression_sql(compress_after_hours), [],
           timeout: @query_timeout_ms
         ) do
      {:ok, _result} ->
        :ok

      {:error, error} ->
        Logger.warning("Failed to reconcile timeseries_metrics compression",
          compress_after_hours: compress_after_hours,
          reason: Exception.message(error)
        )
    end
  end

  defp timeseries_metrics_compress_after_hours(config) do
    compress_after_hours =
      config
      |> Keyword.get(
        :timeseries_metrics_compress_after_hours,
        @default_timeseries_metrics_compress_after_hours
      )
      |> positive_integer(@default_timeseries_metrics_compress_after_hours)

    retention_days =
      config
      |> Keyword.get(
        :timeseries_metrics_retention_days,
        @default_timeseries_metrics_retention_days
      )
      |> positive_integer(@default_timeseries_metrics_retention_days)

    if compress_after_hours >= retention_days * 24 do
      Logger.warning(
        "timeseries_metrics compression lag is not shorter than its retention; " <>
          "chunks are dropped before they are compressed",
        compress_after_hours: compress_after_hours,
        retention_days: retention_days
      )
    end

    compress_after_hours
  end

  defp timeseries_metrics_compression_sql(compress_after_hours) do
    """
    DO $$
    DECLARE
      ts_schema text;
      compress_after interval := make_interval(hours => #{compress_after_hours});
      current_after interval;
    BEGIN
      SELECT n.nspname
      INTO ts_schema
      FROM pg_extension e
      JOIN pg_namespace n ON n.oid = e.extnamespace
      WHERE e.extname = 'timescaledb';

      IF ts_schema IS NULL THEN
        RETURN;
      END IF;

      -- segmentby/orderby belong to the migration; without them there is
      -- nothing for a policy to run.
      IF NOT EXISTS (
        SELECT 1
        FROM timescaledb_information.hypertables
        WHERE hypertable_schema = 'platform'
          AND hypertable_name = 'timeseries_metrics'
          AND compression_enabled
      ) THEN
        RETURN;
      END IF;

      SELECT (j.config->>'compress_after')::interval
      INTO current_after
      FROM timescaledb_information.jobs j
      WHERE j.proc_name = 'policy_compression'
        AND j.hypertable_schema = 'platform'
        AND j.hypertable_name = 'timeseries_metrics'
      LIMIT 1;

      IF current_after IS DISTINCT FROM compress_after THEN
        EXECUTE format(
          'SELECT %I.remove_compression_policy(%L::regclass, if_exists => true)',
          ts_schema,
          'platform.timeseries_metrics'
        );

        EXECUTE format(
          'SELECT %I.add_compression_policy(%L::regclass, compress_after => %L::interval)',
          ts_schema,
          'platform.timeseries_metrics',
          compress_after
        );
      END IF;
    END;
    $$;
    """
  end

  @doc """
  Reconcile retention, chunk interval and compression for the hourly metric
  rollups (continuous aggregates).

  Their migrations register a fixed 395-day retention and no compression, so
  without this they grow until the volume fills. Views that are absent, or a
  database without TimescaleDB, are skipped.
  """
  @spec reconcile_hourly_rollups(keyword()) :: :ok
  def reconcile_hourly_rollups(config) do
    retention_days = hourly_rollup_retention_days(config)

    Enum.each(@hourly_rollups, fn view ->
      run_rollup_sql(view, :retention, rollup_retention_sql(view, retention_days))
      run_rollup_sql(view, :compression, rollup_compression_sql(view))
    end)
  end

  defp hourly_rollup_retention_days(config) do
    configured =
      config
      |> Keyword.get(:hourly_rollup_retention_days, @default_hourly_rollup_retention_days)
      |> positive_integer(@default_hourly_rollup_retention_days)

    if configured < @min_hourly_rollup_retention_days do
      Logger.warning("Hourly rollup retention is below the rollup refresh window; clamping",
        configured_days: configured,
        applied_days: @min_hourly_rollup_retention_days
      )
    end

    max(configured, @min_hourly_rollup_retention_days)
  end

  defp rollup_retention_sql(view, retention_days) do
    """
    DO $$
    DECLARE
      ts_schema text;
      retention interval := make_interval(days => #{retention_days});
      current_drop interval;
    BEGIN
      SELECT n.nspname
      INTO ts_schema
      FROM pg_extension e
      JOIN pg_namespace n ON n.oid = e.extnamespace
      WHERE e.extname = 'timescaledb';

      IF ts_schema IS NULL THEN
        RETURN;
      END IF;

      IF NOT EXISTS (
        SELECT 1
        FROM timescaledb_information.continuous_aggregates
        WHERE view_schema = 'platform'
          AND view_name = '#{view}'
      ) THEN
        RETURN;
      END IF;

      -- jobs records a CAGG policy against either the view or its
      -- materialization hypertable depending on the TimescaleDB version.
      SELECT (j.config->>'drop_after')::interval
      INTO current_drop
      FROM timescaledb_information.continuous_aggregates ca
      JOIN timescaledb_information.jobs j
        ON j.proc_name = 'policy_retention'
       AND j.hypertable_schema IN (ca.materialization_hypertable_schema, ca.view_schema)
       AND j.hypertable_name IN (ca.materialization_hypertable_name, ca.view_name)
      WHERE ca.view_schema = 'platform'
        AND ca.view_name = '#{view}'
      LIMIT 1;

      -- add_retention_policy resets the job's next_start, so only re-register
      -- the policy when the window actually changed.
      IF current_drop IS DISTINCT FROM retention THEN
        EXECUTE format(
          'SELECT %I.remove_retention_policy(%L::regclass, if_exists => true)',
          ts_schema,
          'platform.#{view}'
        );

        EXECUTE format(
          'SELECT %I.add_retention_policy(%L::regclass, %L::interval, if_not_exists => true)',
          ts_schema,
          'platform.#{view}',
          retention
        );
      END IF;

      EXECUTE format(
        'SELECT %I.drop_chunks(%L::regclass, older_than => now() - %L::interval)',
        ts_schema,
        'platform.#{view}',
        retention
      );
    END;
    $$;
    """
  end

  defp rollup_compression_sql(view) do
    """
    DO $$
    DECLARE
      ts_schema text;
      mat regclass;
      compressed boolean;
    BEGIN
      SELECT n.nspname
      INTO ts_schema
      FROM pg_extension e
      JOIN pg_namespace n ON n.oid = e.extnamespace
      WHERE e.extname = 'timescaledb';

      IF ts_schema IS NULL THEN
        RETURN;
      END IF;

      SELECT format('%I.%I', ca.materialization_hypertable_schema, ca.materialization_hypertable_name)::regclass,
             ca.compression_enabled
      INTO mat, compressed
      FROM timescaledb_information.continuous_aggregates ca
      WHERE ca.view_schema = 'platform'
        AND ca.view_name = '#{view}';

      IF mat IS NULL THEN
        RETURN;
      END IF;

      EXECUTE format(
        'SELECT %I.set_chunk_time_interval(%L::regclass, INTERVAL ''#{@hourly_rollup_chunk_interval_hours} hours'')',
        ts_schema,
        mat
      );

      -- Segment-by defaults to the view's GROUP BY columns.
      IF NOT compressed THEN
        EXECUTE 'ALTER MATERIALIZED VIEW platform.#{view} SET (timescaledb.compress = true)';
      END IF;

      EXECUTE format(
        'SELECT %I.add_compression_policy(%L::regclass, compress_after => INTERVAL ''#{@hourly_rollup_compress_after_days} days'', if_not_exists => true)',
        ts_schema,
        'platform.#{view}'
      );
    END;
    $$;
    """
  end

  defp run_rollup_sql(view, step, sql) do
    case SQL.query(Repo, sql, [], timeout: @query_timeout_ms) do
      {:ok, _result} ->
        :ok

      {:error, error} ->
        Logger.warning("Failed to reconcile hourly rollup",
          view: view,
          step: step,
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

  # The shared row batch_size is not passed: here a "row" is a scan that owns
  # hundreds of package rows, and EndpointInventoryRetention bounds its own
  # statements and its scans per run.
  defp prune_endpoint_inventory(config) do
    retention_days =
      config
      |> Keyword.get(
        :endpoint_inventory_retention_days,
        @default_endpoint_inventory_retention_days
      )
      |> EndpointInventorySettingsRuntime.retention_days()

    case EndpointInventoryRetention.prune(
           retention_days: retention_days,
           timeout: Keyword.get(config, :endpoint_inventory_datasvc_timeout_ms, 30_000)
         ) do
      {:ok, %{deleted_scans: deleted}} ->
        deleted

      {:error, error} ->
        Logger.warning("Failed to prune retained endpoint inventory data: #{format_error(error)}")

        0
    end
  end

  defp format_error(error) when is_exception(error), do: Exception.message(error)
  defp format_error(error), do: inspect(error)

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

  defp prune_seasonal_disposition_states(config, batch_size) do
    effective_batch_size =
      config
      |> Keyword.get(:seasonal_disposition_state_batch_size, batch_size)
      |> positive_integer(batch_size)

    case StateStore.cleanup_expired(repo: Repo, batch_size: effective_batch_size) do
      {:ok, deleted} ->
        if deleted > 0 do
          Logger.info("Pruned expired seasonal disposition states",
            deleted_rows: deleted,
            batch_size: effective_batch_size
          )
        end

        deleted

      {:error, %Postgrex.Error{postgres: %{code: :undefined_table}}} ->
        0

      {:error, error} ->
        Logger.warning(
          "Failed to prune expired seasonal disposition states: #{format_error(error)}"
        )

        0
    end
  end

  defp positive_integer(value, _default) when is_integer(value) and value > 0, do: value
  defp positive_integer(_value, default), do: default
end
