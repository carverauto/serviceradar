defmodule ServiceRadar.Observability.TimeseriesSeriesIdentityCardinalityTest do
  use ExUnit.Case, async: true

  @migration_path "priv/repo/migrations/20260622183000_fix_timeseries_series_identity_cardinality.exs"
  @retention_worker_path "lib/serviceradar/observability/data_retention_worker.ex"

  test "migration keeps DB-side series identity aligned with BEAM volatile tags" do
    migration = File.read!(@migration_path)

    for tag <- [
          "execution_id",
          "sweep_group_id",
          "used_bytes",
          "total_bytes",
          "status",
          "source",
          "payload_kind",
          "producer_id",
          "producer_kind"
        ] do
      assert migration =~ ~s("#{tag}")
    end

    assert migration =~ "CREATE OR REPLACE FUNCTION platform.timeseries_series_stable_tags"
  end

  test "migration shrinks raw metric hypertable chunks so 7-day retention can reclaim space" do
    migration = File.read!(@migration_path)

    for table <- [
          "timeseries_metrics",
          "cpu_metrics",
          "cpu_cluster_metrics",
          "disk_metrics",
          "memory_metrics",
          "process_metrics"
        ] do
      assert migration =~ ~s("#{table}")
    end

    assert migration =~ "shrink_chunk_interval(table_name, 24)"
    assert migration =~ "replace_retention_policy(table_name, 7)"
  end

  test "retention worker continuously reconciles raw metric retention and chunks" do
    worker = File.read!(@retention_worker_path)

    assert worker =~ "@default_raw_metrics_retention_days 7"
    assert worker =~ "@default_raw_metrics_chunk_interval_hours 24"
    assert worker =~ ":raw_metrics_retention_days"
    assert worker =~ ":raw_metrics_chunk_interval_hours"
    assert worker =~ ~s("timeseries_metrics")
    assert worker =~ ~s("process_metrics")
  end
end
