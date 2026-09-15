defmodule ServiceRadar.Observability.DataRetentionWorkerTest do
  use ExUnit.Case, async: true

  @moduletag :requires_app

  @worker_path "lib/serviceradar/observability/data_retention_worker.ex"
  @runtime_config_path "config/runtime.exs"
  @ocsf_events_migration_path "priv/repo/migrations/20260203120000_create_ocsf_events.exs"
  @metrics_compression_migration_path "priv/repo/migrations/20260915210000_enable_timeseries_metrics_compression.exs"

  test "worker reconciles retention and chunk intervals for high-volume hypertables" do
    worker = File.read!(@worker_path)

    for {table, retention_key, chunk_key} <- [
          {"otel_traces", ":otel_traces_retention_days", ":otel_traces_chunk_interval_hours"},
          {"logs", ":logs_retention_days", ":logs_chunk_interval_hours"},
          {"otel_metrics", ":otel_metrics_retention_days", ":otel_metrics_chunk_interval_hours"},
          {"otel_metric_points", ":otel_metric_points_retention_days",
           ":otel_metric_points_chunk_interval_hours"},
          {"ocsf_events", ":ocsf_events_retention_days", ":ocsf_events_chunk_interval_hours"},
          {"ocsf_network_activity", ":ocsf_network_activity_retention_days",
           ":ocsf_network_activity_chunk_interval_hours"},
          {"capacity_forecasts", ":capacity_forecasts_retention_days",
           ":capacity_forecasts_chunk_interval_hours"}
        ] do
      assert worker =~ ~s("#{table}")
      assert worker =~ retention_key
      assert worker =~ chunk_key
    end

    assert worker =~ "@default_ocsf_events_retention_days 14"
    assert worker =~ "@default_ocsf_events_chunk_interval_hours 6"
    assert worker =~ "skip_timescale_retention?"
    assert worker =~ "AnalyticsStore.CaggRefresh.reconcile"
    assert worker =~ "AnalyticsStore.Pruner.prune_expired"
  end

  test "runtime config exposes ocsf event retention and chunk controls" do
    runtime_config = File.read!(@runtime_config_path)

    assert runtime_config =~ "SERVICERADAR_OCSF_EVENTS_RETENTION_DAYS"
    assert runtime_config =~ "SERVICERADAR_OCSF_EVENTS_CHUNK_INTERVAL_HOURS"
    assert runtime_config =~ "ocsf_events_retention_days: ocsf_events_retention_days"
    assert runtime_config =~ "ocsf_events_chunk_interval_hours: ocsf_events_chunk_interval_hours"
  end

  test "ocsf events migration keeps a creation-time retention policy" do
    migration = File.read!(@ocsf_events_migration_path)

    assert migration =~ ~s(@table "ocsf_events")
    assert migration =~ ~s(@retention_interval "14 days")
    assert migration =~ "create_hypertable"
    assert migration =~ "PRIMARY KEY (time, id)"
    assert migration =~ "add_retention_policy(@table, @retention_interval)"
    assert migration =~ "remove_retention_policy(@table)"
  end

  test "metrics compression is schema-managed and background-only with a bounded rollback" do
    migration = File.read!(@metrics_compression_migration_path)
    assert migration =~ "serviceradar:allow-startup-maintenance"
    assert migration =~ "IF ts_schema IS NULL"
    assert migration =~ "IF NOT FOUND THEN"
    assert migration =~ "IF NOT compression_enabled THEN"
    assert migration =~ "ALTER TABLE platform.timeseries_metrics"
    assert migration =~ "timescaledb.compress_segmentby = 'metric_type, metric_name, device_id'"
    assert migration =~ "timescaledb.compress_orderby = 'timestamp DESC'"

    assert migration =~
             "add_compression_policy(%L::regclass, INTERVAL ''2 days'', if_not_exists => true)"

    assert migration =~ "remove_compression_policy(%L::regclass, if_exists => true)"
    refute migration =~ "compress_chunk("
    refute migration =~ "decompress_chunk("
    refute migration =~ "ocsf_network_activity"
    refute migration =~ "WHEN others"
  end
end
