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

  TimescaleDB propagates a plain `CREATE INDEX` on a hypertable to all chunks,
  mirroring the existing logs-hypertable index migrations
  (`idx_logs_effective_timestamp`, `idx_logs_id`). It is idempotent via
  `IF NOT EXISTS`, so environments where the index was pre-created out-of-band
  (e.g. `CREATE INDEX CONCURRENTLY` on a large live database) will no-op.
  """
  use Ecto.Migration

  def up do
    execute("""
    CREATE INDEX IF NOT EXISTS idx_logs_severity_lower_effective_ts
    ON platform.logs (lower(severity_text), (COALESCE(observed_timestamp, timestamp)) DESC)
    """)
  end

  def down do
    execute("DROP INDEX IF EXISTS platform.idx_logs_severity_lower_effective_ts")
  end
end
