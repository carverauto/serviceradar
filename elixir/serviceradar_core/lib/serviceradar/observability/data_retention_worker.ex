defmodule ServiceRadar.Observability.DataRetentionWorker do
  @moduledoc """
  Recurring cleanup and retention reconciliation for high-volume observability tables,
  including Timescale hypertable chunk intervals, compression policies, and hourly rollups.
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
  @default_capacity_forecasts_retention_days 395
  @default_raw_metrics_retention_days 7
  @default_timeseries_metrics_retention_days 7
  # Raw timeseries_metrics is the largest table and is only small once
  # compressed, so chunk size and the lag before compression set the disk
  # footprint. Compressing a chunk sorts all of it through temp files on the
  # data volume, so a chunk must stay small relative to free space: a
  # day-long chunk at sweep volume needs tens of GB free and fails on a tight
  # disk. 4-hour chunks compressed 2 hours after closing keep a few hours raw.
  @default_timeseries_metrics_chunk_interval_hours 4
  @default_timeseries_metrics_compress_after_hours 2
  @timeseries_metrics_compression_schedule_hours 1
  @default_otel_traces_chunk_interval_hours 1
  @default_logs_chunk_interval_hours 6
  @default_otel_metrics_chunk_interval_hours 24
  @default_otel_metric_points_chunk_interval_hours 6
  @default_ocsf_events_chunk_interval_hours 6
  @default_capacity_forecasts_chunk_interval_hours 24
  @default_raw_metrics_chunk_interval_hours 24
  # Raw CNPG telemetry a small install can cap with one value. Capacity
  # forecasts stay on their own window: a short telemetry ceiling must not
  # discard the forecast horizon. Hourly rollups are included, then floored
  # at the refresh window below.
  @cnpg_telemetry_ceiling_keys [
    :trace_summary_retention_days,
    :otel_traces_retention_days,
    :logs_retention_days,
    :otel_metrics_retention_days,
    :otel_metric_points_retention_days,
    :ocsf_events_retention_days,
    :timeseries_metrics_retention_days,
    :raw_metrics_retention_days,
    :hourly_rollup_retention_days,
    :adhoc_scan_results_retention_days,
    :service_status_retention_days,
    :spans_red_retention_days,
    :otel_metrics_hourly_stats_retention_days
  ]
  # Hypertables and continuous aggregates whose retention only migrations set
  # before this worker reconciled them. Defaults equal the migration values,
  # so an unset install keeps today's windows. Reconciliation is retention
  # only: chunk intervals and compression stay migration-owned. Endpoint
  # inventory history keeps its own horizon like capacity forecasts.
  # traces_stats_5m stays off the ceiling too: the cold-tier fence is a
  # second owner of its window.
  @default_adhoc_scan_results_retention_days 30
  @default_service_status_retention_days 14
  @default_endpoint_inventory_history_retention_days 395
  @default_spans_red_retention_days 90
  @default_traces_stats_retention_days 14
  @default_otel_metrics_hourly_stats_retention_days 90

  # {table, retention_key, retention_default}
  @migration_tables [
    {"adhoc_scan_results", :adhoc_scan_results_retention_days,
     @default_adhoc_scan_results_retention_days},
    {"service_status", :service_status_retention_days, @default_service_status_retention_days},
    {"events", :service_status_retention_days, @default_service_status_retention_days},
    {"endpoint_inventory_scan_history", :endpoint_inventory_history_retention_days,
     @default_endpoint_inventory_history_retention_days},
    {"endpoint_inventory_package_events", :endpoint_inventory_history_retention_days,
     @default_endpoint_inventory_history_retention_days},
    {"endpoint_inventory_package_count_history", :endpoint_inventory_history_retention_days,
     @default_endpoint_inventory_history_retention_days},
    {"endpoint_inventory_cpe_count_history", :endpoint_inventory_history_retention_days,
     @default_endpoint_inventory_history_retention_days}
  ]
  # {view, retention_key, retention_default}. traces_stats_5m is reconciled
  # separately because of the cold-tier widened window.
  @migration_caggs [
    {"spans_red_1h", :spans_red_retention_days, @default_spans_red_retention_days},
    {"otel_metrics_hourly_stats", :otel_metrics_hourly_stats_retention_days,
     @default_otel_metrics_hourly_stats_retention_days}
  ]
  # {table, retention_key, retention_default, chunk_key, chunk_default}
  @timescale_tables [
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
    {"capacity_forecasts", :capacity_forecasts_retention_days,
     @default_capacity_forecasts_retention_days, :capacity_forecasts_chunk_interval_hours,
     @default_capacity_forecasts_chunk_interval_hours},
    {"timeseries_metrics", :timeseries_metrics_retention_days,
     @default_timeseries_metrics_retention_days, :timeseries_metrics_chunk_interval_hours,
     @default_timeseries_metrics_chunk_interval_hours},
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
  ]
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
  # {view, retention_key, retention_default, default_start_hours, end_offset, schedule_interval}
  #
  # Default start_offset windows stay strictly below the minimum 1-day retention
  # for sub-day rollups (`spans_red_1h`, `traces_stats_5m`, `logs_severity_stats_5m`)
  # and strictly below the default raw retention for multi-day rollups. When an
  # operator lowers a raw source table's retention, `cagg_refresh_policy_specs/1`
  # clamps `start_offset` below that source retention so policy refreshes never
  # recompute dropped raw regions as empty.
  @cagg_refresh_policies [
    {"cpu_metrics_hourly", :raw_metrics_retention_days, @default_raw_metrics_retention_days,
     5 * 24, "10 minutes", "10 minutes"},
    {"memory_metrics_hourly", :raw_metrics_retention_days, @default_raw_metrics_retention_days,
     5 * 24, "10 minutes", "10 minutes"},
    {"disk_metrics_hourly", :raw_metrics_retention_days, @default_raw_metrics_retention_days,
     5 * 24, "10 minutes", "10 minutes"},
    {"process_metrics_hourly", :raw_metrics_retention_days, @default_raw_metrics_retention_days,
     5 * 24, "10 minutes", "10 minutes"},
    {"timeseries_metrics_hourly", :timeseries_metrics_retention_days,
     @default_timeseries_metrics_retention_days, 5 * 24, "10 minutes", "10 minutes"},
    {"timeseries_metrics_disk_hourly", :timeseries_metrics_retention_days,
     @default_timeseries_metrics_retention_days, 5 * 24, "10 minutes", "10 minutes"},
    {"timeseries_metrics_interface_hourly", :timeseries_metrics_retention_days,
     @default_timeseries_metrics_retention_days, 5 * 24, "10 minutes", "10 minutes"},
    {"spans_red_1h", :otel_traces_retention_days, @default_otel_traces_retention_days, 12,
     "10 minutes", "10 minutes"},
    {"traces_stats_5m", :otel_traces_retention_days, @default_otel_traces_retention_days, 12,
     "5 minutes", "5 minutes"},
    {"otel_metrics_hourly_stats", :otel_metrics_retention_days,
     @default_otel_metrics_retention_days, 28 * 24, "10 minutes", "10 minutes"},
    {"ocsf_events_hourly_stats", :ocsf_events_retention_days, @default_ocsf_events_retention_days,
     26, "5 minutes", "5 minutes"},
    {"logs_severity_stats_5m", :logs_retention_days, @default_logs_retention_days, 3,
     "30 minutes", "10 minutes"},
    {"endpoint_inventory_package_counts_hourly", :endpoint_inventory_history_retention_days,
     @default_endpoint_inventory_history_retention_days, 31 * 24, "5 minutes", "5 minutes"},
    {"endpoint_inventory_cpe_counts_hourly", :endpoint_inventory_history_retention_days,
     @default_endpoint_inventory_history_retention_days, 31 * 24, "5 minutes", "5 minutes"},
    {"services_availability_5m", :service_status_retention_days,
     @default_service_status_retention_days, 24, "5 minutes", "5 minutes"}
  ]
  @query_timeout_ms 120_000

  @impl Oban.Worker
  def perform(_job) do
    config = Application.get_env(:serviceradar_core, __MODULE__, [])
    batch_size = Keyword.get(config, :batch_size, @default_batch_size)

    reconcile_timescale_tables(config)
    reconcile_migration_tables(config)
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

  @doc """
  Retention, in days, that the next reconciliation applies to each raw
  telemetry hypertable and to `otel_trace_summaries`.

  `:cnpg_telemetry_default_days`, when a positive integer, is a ceiling on
  raw telemetry. A per-table value may be shorter. Capacity forecasts are
  not capped by that ceiling.
  """
  @spec telemetry_retention_days(keyword()) :: %{String.t() => pos_integer()}
  def telemetry_retention_days(config) when is_list(config) do
    tables =
      Map.new(@timescale_tables, fn {table, key, default, _chunk_key, _chunk_default} ->
        {table, retention_days(config, key, default)}
      end)

    Map.put(
      tables,
      "otel_trace_summaries",
      retention_days(
        config,
        :trace_summary_retention_days,
        @default_trace_summary_retention_days
      )
    )
  end

  @doc """
  Reconcile retention and chunk interval for the raw telemetry hypertables.

  `timeseries_metrics` takes its chunk interval from
  `:timeseries_metrics_chunk_interval_hours`; the sysmon tables share
  `:raw_metrics_chunk_interval_hours`. A new interval applies to chunks
  created afterwards.
  """
  @spec reconcile_timescale_tables(keyword()) :: :ok
  def reconcile_timescale_tables(config) do
    reconcile_cagg_refresh_windows(config)
    applied = telemetry_retention_days(config)

    Enum.each(@timescale_tables, fn {table_name, _key, _default, chunk_key, chunk_default} ->
      retention_days = Map.fetch!(applied, table_name)

      chunk_hours =
        config |> Keyword.get(chunk_key, chunk_default) |> positive_integer(chunk_default)

      # All in-DB policy DDL goes through the cold-tier fence: unfenced
      # tables keep today's remove+add behavior; fenced (offloaded) tables
      # get their in-DB policy removed so only the gated drop below can
      # ever discard data.
      RetentionFence.reconcile_policy(table_name, retention_days)
      set_chunk_interval(table_name, chunk_hours)
      drop_expired_chunks(table_name, retention_days)
    end)
  end

  @doc """
  Reconcile retention for the hypertables and continuous aggregates that
  only migrations configured before this pass existed.

  Retention only: chunk intervals and compression for these objects stay
  migration-owned. Refresh windows are clamped first, through the same
  specs `reconcile_timescale_tables/1` uses, so a shortened source never
  leaves a wider refresh registered. Objects that do not exist are
  skipped.
  """
  @spec reconcile_migration_tables(keyword()) :: :ok
  def reconcile_migration_tables(config) do
    reconcile_cagg_refresh_windows(config)

    Enum.each(@migration_tables, fn {table_name, key, default} ->
      days = retention_days(config, key, default)
      RetentionFence.reconcile_policy(table_name, days)
      drop_expired_chunks(table_name, days)
    end)

    Enum.each(@migration_caggs, fn {view, key, default} ->
      days = migration_cagg_retention_days(config, view, key, default)
      run_rollup_sql(view, :retention, rollup_retention_sql(view, days))
    end)

    reconcile_traces_stats_retention(config)
  end

  # A continuous aggregate's retention, floored at its already-clamped
  # refresh window. The clamp keeps the window strictly under the
  # configured retention, so the floor never holds drop_after above it.
  defp migration_cagg_retention_days(config, view, key, default) do
    configured = retention_days(config, key, default)

    floor_days =
      case Enum.find(cagg_refresh_policy_specs(config), &(&1.view == view)) do
        %{start_offset_hours: hours} -> div(hours + 23, 24)
        nil -> 1
      end

    max(configured, floor_days)
  end

  # traces_stats_5m also has a cold-tier owner. The target is the explicit
  # tracesStatsDays when set, otherwise the 14-day migration default, floored
  # at the clamped refresh window. The telemetry ceiling does not apply.
  # While the tier is enabled, a target shorter than the fence window is not
  # written. While it is disabled, an unset key leaves a window already at
  # or above that fence target unchanged. An explicit value may narrow or
  # raise the window, including above the fence target.
  defp reconcile_traces_stats_retention(config) do
    query_result = query_cagg_retention_days("traces_stats_5m")

    case traces_stats_retention_to_apply(config, query_result, Config.enabled?()) do
      {:skip, :unreadable} ->
        Logger.warning(
          "Skipped traces_stats_5m retention; the current drop_after could not be read",
          reason: cagg_retention_read_reason(query_result)
        )

      :skip ->
        :ok

      days ->
        run_rollup_sql(
          "traces_stats_5m",
          :retention,
          rollup_retention_sql("traces_stats_5m", days)
        )
    end
  end

  @doc """
  Days to write onto `traces_stats_5m`, `:skip` when the installed window must
  stay, or `{:skip, :unreadable}` when the catalog read did not prove the window.

  `query_result` is the `{:ok, %{rows: _}} | {:error, _}` result of reading
  `drop_after`. `cold_tier_enabled?` is `ColdTier.Config.enabled?/0`.

  The target is an explicit `traces_stats_retention_days` when set, otherwise
  the 14-day migration default, floored at the clamped refresh window. The
  telemetry ceiling does not apply. A missing policy is replaced with that
  target. While the cold tier is enabled, a target shorter than
  `RetentionFence.cagg_cold_window_days/1` is not written. While the tier is
  disabled, an unset key leaves a window already at or above that fence target
  unchanged. Every other installed window is set to the target, so an explicit
  value may narrow or raise it, including above the fence target.
  """
  @spec traces_stats_retention_to_apply(
          keyword(),
          {:ok, map()} | {:error, term()},
          boolean()
        ) :: :skip | {:skip, :unreadable} | pos_integer()
  def traces_stats_retention_to_apply(config, query_result, cold_tier_enabled?)
      when is_list(config) and is_boolean(cold_tier_enabled?) do
    case normalize_cagg_retention_read(query_result) do
      {:error, _reason} ->
        {:skip, :unreadable}

      {:ok, current} ->
        traces_stats_retention_days_to_apply(config, current, cold_tier_enabled?)
    end
  end

  defp traces_stats_retention_days_to_apply(config, current, cold_tier_enabled?) do
    explicit = positive_integer(Keyword.get(config, :traces_stats_retention_days), nil)
    cold_window = RetentionFence.cagg_cold_window_days("traces_stats_5m")

    desired =
      migration_cagg_retention_days(
        config,
        "traces_stats_5m",
        :traces_stats_retention_days,
        @default_traces_stats_retention_days
      )

    cond do
      is_nil(current) ->
        desired

      cold_tier_enabled? and is_integer(cold_window) and desired < cold_window ->
        :skip

      not cold_tier_enabled? and is_nil(explicit) and is_integer(current) and
        is_integer(cold_window) and current >= cold_window ->
        :skip

      true ->
        desired
    end
  end

  defp query_cagg_retention_days(view) do
    sql = """
    SELECT (EXTRACT(EPOCH FROM (j.config->>'drop_after')::interval) / 86400)::float8
    FROM timescaledb_information.continuous_aggregates ca
    JOIN timescaledb_information.jobs j
      ON j.proc_name = 'policy_retention'
     AND j.hypertable_schema IN (ca.materialization_hypertable_schema, ca.view_schema)
     AND j.hypertable_name IN (ca.view_name, ca.materialization_hypertable_name)
    WHERE ca.view_schema = 'platform' AND ca.view_name = $1
    LIMIT 1
    """

    SQL.query(Repo, sql, [view], timeout: @query_timeout_ms)
  end

  defp normalize_cagg_retention_read({:ok, %{rows: [[days]]}}) when is_number(days) do
    {:ok, round(days)}
  end

  defp normalize_cagg_retention_read({:ok, %{rows: [[nil]]}}), do: {:ok, nil}
  defp normalize_cagg_retention_read({:ok, %{rows: []}}), do: {:ok, nil}
  defp normalize_cagg_retention_read({:error, reason}), do: {:error, reason}

  defp normalize_cagg_retention_read({:ok, other}) do
    {:error, {:unexpected_cagg_retention_row, other}}
  end

  defp cagg_retention_read_reason({:error, reason}), do: format_error(reason)
  defp cagg_retention_read_reason(other), do: inspect(other)

  # otel_metrics_hourly_stats refreshes from raw otel metrics into itself:
  # its window must stay under both the raw retention and its own.
  defp cagg_source_retention_days(config, "otel_metrics_hourly_stats", key, default) do
    min(
      retention_days(config, key, default),
      retention_days(
        config,
        :otel_metrics_hourly_stats_retention_days,
        @default_otel_metrics_hourly_stats_retention_days
      )
    )
  end

  defp cagg_source_retention_days(config, _view, key, default) do
    retention_days(config, key, default)
  end

  @doc """
  Retention, in days, for one worker retention key.

  Applies `:cnpg_telemetry_default_days` when it is a positive integer and
  the key is raw telemetry. Capacity forecasts stay on their own window.
  The cold tier reads hot retention through this function.
  """
  @spec retention_days(keyword(), atom(), pos_integer()) :: pos_integer()
  def retention_days(config, key, default) when is_list(config) and is_atom(key) do
    configured =
      config
      |> Keyword.get(key, default)
      |> positive_integer(default)

    ceiling = Keyword.get(config, :cnpg_telemetry_default_days)

    if key in @cnpg_telemetry_ceiling_keys and is_integer(ceiling) and ceiling > 0 do
      min(configured, ceiling)
    else
      configured
    end
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
  # 2.24.0). `reconcile_cagg_refresh_windows/1` clamps the shipped policies
  # to the configured retention; this guard catches what it does not manage
  # (hand-created policies or aggregates outside @cagg_refresh_policies).
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
  `add_compression_policy` resets the job schedule. The job runs hourly so a
  closed chunk does not wait out a 12-hour default schedule. A database
  without TimescaleDB, or a table without compression enabled, is skipped.
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
      retention_days(
        config,
        :timeseries_metrics_retention_days,
        @default_timeseries_metrics_retention_days
      )

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
      schedule interval := make_interval(hours => #{@timeseries_metrics_compression_schedule_hours});
      current_after interval;
      current_job integer;
      current_schedule interval;
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
          'SELECT %I.add_compression_policy(%L::regclass, compress_after => %L::interval, schedule_interval => %L::interval)',
          ts_schema,
          'platform.timeseries_metrics',
          compress_after,
          schedule
        );
      END IF;

      SELECT j.job_id, j.schedule_interval
      INTO current_job, current_schedule
      FROM timescaledb_information.jobs j
      WHERE j.proc_name = 'policy_compression'
        AND j.hypertable_schema = 'platform'
        AND j.hypertable_name = 'timeseries_metrics'
      LIMIT 1;

      IF current_job IS NOT NULL AND current_schedule IS DISTINCT FROM schedule THEN
        EXECUTE format(
          'SELECT %I.alter_job(%s, schedule_interval => %L::interval)',
          ts_schema,
          current_job,
          schedule
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

  @doc """
  Narrow continuous-aggregate refresh windows (`start_offset`) so every rollup
  stays strictly inside its raw source table's retention window. A window that
  is already narrower is kept. Raises on failure so raw retention is never
  lowered while a wider refresh window is still registered.
  """
  @spec reconcile_cagg_refresh_windows(keyword()) :: :ok
  def reconcile_cagg_refresh_windows(config \\ []) do
    Enum.each(cagg_refresh_policy_specs(config), fn %{
                                                      view: view,
                                                      start_offset: start_offset,
                                                      end_offset: end_offset,
                                                      schedule_interval: schedule_interval
                                                    } ->
      SQL.query!(
        Repo,
        cagg_refresh_policy_sql(view, start_offset, end_offset, schedule_interval),
        [],
        timeout: @query_timeout_ms
      )
    end)
  end

  @doc """
  Effective continuous-aggregate refresh policy specifications for `config`,
  with each `start_offset` clamped strictly below its raw source's retention.
  """
  @spec cagg_refresh_policy_specs(keyword()) :: [map()]
  def cagg_refresh_policy_specs(config \\ []) do
    Enum.map(@cagg_refresh_policies, fn {view, retention_key, retention_default,
                                         default_start_hours, end_offset, schedule_interval} ->
      retention_days =
        cagg_source_retention_days(config, view, retention_key, retention_default)

      start_offset_hours = clamp_cagg_start_offset_hours(default_start_hours, retention_days)

      %{
        view: view,
        source_retention_days: retention_days,
        start_offset_hours: start_offset_hours,
        start_offset: format_cagg_interval_hours(start_offset_hours),
        end_offset: end_offset,
        schedule_interval: schedule_interval
      }
    end)
  end

  defp clamp_cagg_start_offset_hours(default_start_hours, 1) do
    min(default_start_hours, 12)
  end

  defp clamp_cagg_start_offset_hours(default_start_hours, retention_days)
       when is_integer(retention_days) and retention_days > 1 do
    if default_start_hours < retention_days * 24 and div(default_start_hours, 24) < retention_days do
      default_start_hours
    else
      (retention_days - 1) * 24
    end
  end

  defp format_cagg_interval_hours(hours) when rem(hours, 24) == 0 and hours >= 24 do
    days = div(hours, 24)
    if days == 1, do: "1 day", else: "#{days} days"
  end

  defp format_cagg_interval_hours(hours), do: "#{hours} hours"

  defp cagg_refresh_policy_sql(view, start_offset, end_offset, schedule_interval) do
    """
    DO $$
    DECLARE
      ts_schema text;
      target_start interval := INTERVAL '#{start_offset}';
      current_start interval;
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

      SELECT (j.config->>'start_offset')::interval
      INTO current_start
      FROM timescaledb_information.continuous_aggregates ca
      JOIN timescaledb_information.jobs j
        ON j.proc_name = 'policy_refresh_continuous_aggregate'
       AND j.hypertable_schema IN (ca.materialization_hypertable_schema, ca.view_schema)
       AND j.hypertable_name IN (ca.materialization_hypertable_name, ca.view_name)
      WHERE ca.view_schema = 'platform'
        AND ca.view_name = '#{view}'
      LIMIT 1;

      IF current_start IS NULL OR target_start < current_start THEN
        EXECUTE format(
          'SELECT %I.remove_continuous_aggregate_policy(%L::regclass, if_exists => true)',
          ts_schema,
          'platform.#{view}'
        );

        EXECUTE format(
          'SELECT %I.add_continuous_aggregate_policy(%L::regclass, '
          || 'start_offset => %L::interval, '
          || 'end_offset => %L::interval, '
          || 'schedule_interval => %L::interval, '
          || 'if_not_exists => true)',
          ts_schema,
          'platform.#{view}',
          target_start,
          INTERVAL '#{end_offset}',
          INTERVAL '#{schedule_interval}'
        );
      END IF;
    END;
    $$;
    """
  end

  @doc """
  Hourly rollup retention after the telemetry ceiling and the refresh-window
  floor. The floor stays at #{@min_hourly_rollup_retention_days} days so a
  short ceiling cannot make the refresh recompute dropped raw buckets.
  """
  @spec hourly_rollup_retention_days(keyword()) :: pos_integer()
  def hourly_rollup_retention_days(config) do
    configured =
      retention_days(
        config,
        :hourly_rollup_retention_days,
        @default_hourly_rollup_retention_days
      )

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
      Map.fetch!(telemetry_retention_days(config), "otel_trace_summaries")

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
