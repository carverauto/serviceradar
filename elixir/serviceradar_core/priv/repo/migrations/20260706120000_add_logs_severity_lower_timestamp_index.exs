defmodule ServiceRadar.Repo.Migrations.AddLogsSeverityLowerTimestampIndex do
  @moduledoc """
  Adds a composite index that makes the Observability log-level drill-down
  (e.g. the "Fatal" card) fast instead of timing out.

  The drill-down runs an SRQL query like:

      in:logs severity_text:(fatal,critical,emergency,alert,...) time:last_24h sort:timestamp:desc

  which SRQL compiles to a CASE-INSENSITIVE predicate ordered by the logs
  "effective timestamp" `COALESCE(observed_timestamp, timestamp)` (both the
  `time:` range filter and `sort:timestamp` resolve to that expression):

      WHERE COALESCE(observed_timestamp, timestamp) >= $1
        AND COALESCE(observed_timestamp, timestamp) <= $2
        AND lower(severity_text) = ANY($3)
      ORDER BY COALESCE(observed_timestamp, timestamp) DESC
      LIMIT n

  `platform.logs` is a ~10M-row TimescaleDB hypertable whose relevant indexes
  are single-column `idx_logs_severity (severity_text)`,
  `idx_logs_timestamp (timestamp DESC)`, and the expression index
  `idx_logs_effective_timestamp ((COALESCE(observed_timestamp, timestamp)) DESC)`.
  None serve the ordered, case-insensitive severity lookup: the planner falls
  back to an effective-timestamp-ordered ChunkAppend scan that filters
  `severity_text` per chunk, and because fatal/critical rows are extremely
  sparse (~2k of ~5.5M in 24h) it scans deep into every chunk to fill the LIMIT
  and hits the statement timeout.

  The fix is an EXPRESSION composite index on
  `(lower(severity_text), COALESCE(observed_timestamp, timestamp) DESC)`:

    * `lower(severity_text)` is required — a plain `(severity_text, ...)` btree
      index cannot serve the `lower(severity_text) = ANY(...)` predicate the
      query actually emits, and lowering keeps the drill-down consistent with
      the `logs_severity_stats_5m` CAGG that powers the card counts (that CAGG
      also groups by `lower(severity_text)`).
    * the second key `COALESCE(observed_timestamp, timestamp) DESC` matches both
      the time-range filter and the ORDER BY, so the planner can scan one
      per-severity range in descending effective-timestamp order and stop at
      LIMIT instead of sorting the whole window.

  ## Online (per-chunk) build — do NOT hold a hypertable-wide lock

  This migration runs in the Helm `pre-install,pre-upgrade` hook Job, so it
  executes on every `helm upgrade` against an *existing* large deployment. A
  plain `CREATE INDEX` on a hypertable takes `ACCESS EXCLUSIVE` on the whole
  `logs` hypertable and holds it for the entire build, blocking log ingestion
  and stalling the upgrade (the release waits on the hook Job + the
  `wait-migrations` init container) — potentially for minutes on ~10M rows.

  Instead we build the index ONLINE, one chunk at a time, using TimescaleDB's
  `WITH (timescaledb.transaction_per_chunk)`: TimescaleDB commits after each
  chunk's index build, so the hypertable-wide `ACCESS EXCLUSIVE` lock is
  released between chunks rather than held for the whole operation. Ingestion
  only ever contends for the single chunk currently being indexed (typically
  just the newest, hot chunk) for a brief moment.

  `transaction_per_chunk` REQUIRES running outside a transaction block, so both
  `@disable_ddl_transaction` and `@disable_migration_lock` are set (Ecto
  otherwise wraps the migration — and its migration lock — in a transaction,
  and TimescaleDB errors with "CREATE INDEX ... WITH
  (timescaledb.transaction_per_chunk) cannot run inside a transaction block").

  Note: `CREATE INDEX CONCURRENTLY` is NOT an option here — TimescaleDB rejects
  it on hypertables ("hypertables do not support concurrent index creation"),
  which is exactly why `transaction_per_chunk` exists. This is the convention
  for any future index migration on a large hypertable (`logs`, `ocsf_events`,
  `otel_*`, netflow, timeseries, …): `@disable_ddl_transaction true` +
  `@disable_migration_lock true` + `WITH (timescaledb.transaction_per_chunk)`.

  It stays idempotent via `IF NOT EXISTS`, so environments where the index was
  pre-created out-of-band (e.g. a hand-applied plain build on a small DB) will
  no-op.
  """
  use Ecto.Migration

  # Build the index per-chunk in separate short transactions instead of one
  # hypertable-wide ACCESS EXCLUSIVE lock. transaction_per_chunk cannot run
  # inside a transaction block, so the migration (and its lock) must not be
  # wrapped in one.
  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    execute("""
    CREATE INDEX IF NOT EXISTS idx_logs_severity_lower_effective_ts
    ON platform.logs (lower(severity_text), (COALESCE(observed_timestamp, timestamp)) DESC)
    WITH (timescaledb.transaction_per_chunk)
    """)
  end

  def down do
    execute("DROP INDEX IF EXISTS platform.idx_logs_severity_lower_effective_ts")
  end
end
