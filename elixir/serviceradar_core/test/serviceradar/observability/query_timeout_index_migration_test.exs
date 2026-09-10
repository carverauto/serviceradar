defmodule ServiceRadar.Observability.QueryTimeoutIndexMigrationTest do
  use ExUnit.Case, async: true

  @probe_migration_path "priv/repo/migrations/20260909110000_add_timeseries_metrics_probe_index.exs"
  @source_ip_migration_path "priv/repo/migrations/20260909120000_add_logs_source_ip_effective_ts_index.exs"

  test "sysmon presence probes get an ordered composite lookup" do
    migration = File.read!(@probe_migration_path)

    assert migration =~ "idx_timeseries_metrics_probe"
    assert migration =~ "(metric_type, metric_name, device_id, timestamp DESC)"
    assert migration =~ "timescaledb.transaction_per_chunk"
    assert migration =~ "@disable_ddl_transaction true"
    assert migration =~ "@disable_migration_lock true"
    assert migration =~ "DROP INDEX IF EXISTS platform.idx_timeseries_metrics_probe"
    refute migration =~ "CONCURRENTLY"
  end

  test "device log identity probes get an ordered source_ip lookup" do
    migration = File.read!(@source_ip_migration_path)

    assert migration =~ "idx_logs_source_ip_effective_ts"
    assert migration =~ "(source_ip, (COALESCE(observed_timestamp, timestamp)) DESC)"
    assert migration =~ "timescaledb.transaction_per_chunk"
    assert migration =~ "@disable_ddl_transaction true"
    assert migration =~ "@disable_migration_lock true"
    assert migration =~ "DROP INDEX IF EXISTS platform.idx_logs_source_ip_effective_ts"
    refute migration =~ "CONCURRENTLY"
  end
end
