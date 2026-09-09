defmodule ServiceRadar.Repo.Migrations.AddLogsSourceIpEffectiveTsIndex do
  @moduledoc """
  Adds a composite index that makes device-page log queries fast instead of
  deep-scanning the 24h window.

  The device detail logs tab runs an SRQL query like:

      in:logs device_id:"sr:..." time:last_24h sort:timestamp:desc

  which SRQL compiles (via `rust/srql/src/query/logs/metadata.rs`) to
  uncorrelated inventory lookups on the RAW `source_ip`/`source` columns:

      WHERE COALESCE(observed_timestamp, timestamp) >= $1
        AND COALESCE(observed_timestamp, timestamp) <= $2
        AND (logs.source_ip IN (SELECT ...) OR logs.source IN (SELECT ...) ...)
      ORDER BY COALESCE(observed_timestamp, timestamp) DESC
      LIMIT n

  `source` already has the `(source, effective-timestamp)` composite
  (`20260707120000`), but `source_ip` — the half of the identity match every
  syslog row carries — had no index at all. Without an access path the
  planner fell back to an effective-timestamp-ordered scan that filters
  `source_ip` per chunk; when a device's syslog rows are sparse across the
  window it scans deep into every chunk to fill the LIMIT and dies to
  `statement_timeout` (Postgrex `:query_canceled`), leaving the logs tab
  empty while syslog keeps flowing. This index gives the `source_ip`
  branches the same ordered per-value access path the `source` branches
  already had.

  `platform.logs` is a large TimescaleDB hypertable, so the index builds
  online, one chunk per transaction
  (`WITH (timescaledb.transaction_per_chunk)`), outside Ecto's DDL
  transaction and migration lock — the convention for any index migration on
  a large hypertable. Concurrent index builds are not an option:
  TimescaleDB rejects them on hypertables.
  """

  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    execute("""
    CREATE INDEX IF NOT EXISTS idx_logs_source_ip_effective_ts
    ON platform.logs (source_ip, (COALESCE(observed_timestamp, timestamp)) DESC)
    WITH (timescaledb.transaction_per_chunk)
    """)
  end

  def down do
    execute("DROP INDEX IF EXISTS platform.idx_logs_source_ip_effective_ts")
  end
end
