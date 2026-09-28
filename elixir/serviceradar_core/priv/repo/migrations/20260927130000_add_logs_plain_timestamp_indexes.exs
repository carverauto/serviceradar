defmodule ServiceRadar.Repo.Migrations.AddLogsPlainTimestampIndexes do
  @moduledoc """
  Adds plain-timestamp ordered indexes mirroring the effective-timestamp
  (`COALESCE(observed_timestamp, timestamp)`) indexes, now that SRQL windows and
  orders logs by the event `timestamp` on both backends.

  SRQL used to resolve the `time:` range filter and `sort:timestamp` to
  `COALESCE(observed_timestamp, timestamp)`, and the severity/source/source_ip
  drill-down indexes were built on that expression. The window/order alignment
  for #4852 re-pointed the CNPG dialect to bare `timestamp`, so those expression
  indexes can no longer serve the per-value ordered scans. The fatal-card query
  (`in:logs severity_text:(fatal,...) time:last_24h sort:timestamp:desc`)
  then regains the deep per-chunk scan the expression indexes were added to
  avoid.

  These indexes restore the ordered per-value access paths on the plain
  `timestamp` column:

    * `(lower(severity_text), "timestamp" DESC)` for the severity-text branches,
    * `(severity_number, "timestamp" DESC)` for the numeric-severity fallback,
    * `(source, "timestamp" DESC)` for the source drill-down,
    * `(source_ip, "timestamp" DESC)` for the device-page logs lookup.

  `platform.logs` is a large TimescaleDB hypertable. Build one chunk per
  transaction so deployment does not hold a hypertable-wide lock for the full
  index build. TimescaleDB requires this option to run outside Ecto's DDL
  transaction and migration lock.

  Each index is guarded behind `to_regclass('platform.logs') IS NOT NULL` so the
  migration no-ops on installs whose current database has no main log table.
  """

  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  @table "platform.logs"

  def up do
    create_index_if_logs_table_exists("""
    CREATE INDEX IF NOT EXISTS idx_logs_severity_lower_timestamp
    ON platform.logs (lower(severity_text), "timestamp" DESC)
    WITH (timescaledb.transaction_per_chunk)
    """)

    create_index_if_logs_table_exists("""
    CREATE INDEX IF NOT EXISTS idx_logs_severity_number_timestamp
    ON platform.logs (severity_number, "timestamp" DESC)
    WITH (timescaledb.transaction_per_chunk)
    """)

    create_index_if_logs_table_exists("""
    CREATE INDEX IF NOT EXISTS idx_logs_source_timestamp
    ON platform.logs (source, "timestamp" DESC)
    WITH (timescaledb.transaction_per_chunk)
    """)

    create_index_if_logs_table_exists("""
    CREATE INDEX IF NOT EXISTS idx_logs_source_ip_timestamp
    ON platform.logs (source_ip, "timestamp" DESC)
    WITH (timescaledb.transaction_per_chunk)
    """)
  end

  def down do
    execute("DROP INDEX IF EXISTS platform.idx_logs_source_ip_timestamp")
    execute("DROP INDEX IF EXISTS platform.idx_logs_source_timestamp")
    execute("DROP INDEX IF EXISTS platform.idx_logs_severity_number_timestamp")
    execute("DROP INDEX IF EXISTS platform.idx_logs_severity_lower_timestamp")
  end

  defp create_index_if_logs_table_exists(statement) do
    case repo().query!("SELECT to_regclass($1)", [@table]) do
      %{rows: [[nil]]} -> :ok
      %{rows: [[_]]} -> execute(statement)
    end
  end
end
