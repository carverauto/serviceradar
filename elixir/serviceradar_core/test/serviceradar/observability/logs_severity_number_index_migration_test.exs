defmodule ServiceRadar.Observability.LogsSeverityNumberIndexMigrationTest do
  use ExUnit.Case, async: true

  @migration_path "priv/repo/migrations/20260812141000_add_logs_severity_number_effective_ts_index.exs"

  test "builds the numeric severity top-N index safely per hypertable chunk" do
    migration = File.read!(@migration_path)

    assert migration =~ "@disable_ddl_transaction true"
    assert migration =~ "@disable_migration_lock true"
    assert migration =~ "CREATE INDEX IF NOT EXISTS idx_logs_severity_number_effective_ts"

    assert migration =~
             "ON platform.logs (severity_number, (COALESCE(observed_timestamp, timestamp)) DESC)"

    assert migration =~ "WITH (timescaledb.transaction_per_chunk)"
    refute migration =~ "CREATE INDEX CONCURRENTLY"
    assert migration =~ "DROP INDEX IF EXISTS platform.idx_logs_severity_number_effective_ts"
  end
end
