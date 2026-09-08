defmodule ServiceRadar.Repo.Migrations.AddLogsSeverityNumberEffectiveTsIndex do
  @moduledoc """
  Adds the ordered lookup used by SRQL's numeric-severity fallback branches.

  A log's recognized `severity_text` is authoritative, but missing or unknown
  text falls back to the OTel `severity_number`. SRQL implements the clickable
  severity cards as disjoint scalar text and numeric branches, then merges each
  branch's bounded newest rows. The existing lower-text composite index serves
  the text branches; this index gives the numeric branches the equivalent
  `(severity, effective timestamp)` access path.

  `platform.logs` is a large TimescaleDB hypertable. Build one chunk per
  transaction so deployment does not hold a hypertable-wide lock for the full
  index build. TimescaleDB requires this option to run outside Ecto's DDL
  transaction and migration lock.
  """

  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    execute("""
    CREATE INDEX IF NOT EXISTS idx_logs_severity_number_effective_ts
    ON platform.logs (severity_number, (COALESCE(observed_timestamp, timestamp)) DESC)
    WITH (timescaledb.transaction_per_chunk)
    """)
  end

  def down do
    execute("DROP INDEX IF EXISTS platform.idx_logs_severity_number_effective_ts")
  end
end
