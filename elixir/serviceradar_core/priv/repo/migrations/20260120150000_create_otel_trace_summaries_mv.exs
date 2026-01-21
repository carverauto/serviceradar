defmodule ServiceRadar.Repo.Migrations.CreateOtelTraceSummariesMv do
  @moduledoc """
  Creates the otel_trace_summaries materialized view.

  This MV pre-aggregates span data by trace_id for fast trace listing queries.
  It replaces the on-the-fly CTE aggregation that was causing slow dashboard loads.

  The view is refreshed by an Oban job (RefreshTraceSummariesWorker) every 2 minutes.

  This migration is idempotent - safe to run multiple times.
  """
  use Ecto.Migration

  def up do
    # Create the materialized view with a 7-day rolling window
    # This aggregates otel_traces spans into one row per trace
    execute("""
    CREATE MATERIALIZED VIEW IF NOT EXISTS otel_trace_summaries AS
    SELECT
      trace_id,
      max(timestamp) AS timestamp,
      max(span_id) FILTER (WHERE parent_span_id IS NULL OR parent_span_id = '') AS root_span_id,
      max(name) FILTER (WHERE parent_span_id IS NULL OR parent_span_id = '') AS root_span_name,
      max(service_name) FILTER (WHERE parent_span_id IS NULL OR parent_span_id = '') AS root_service_name,
      max(kind) FILTER (WHERE parent_span_id IS NULL OR parent_span_id = '') AS root_span_kind,
      min(start_time_unix_nano) AS start_time_unix_nano,
      max(end_time_unix_nano) AS end_time_unix_nano,
      (max(end_time_unix_nano) - min(start_time_unix_nano))::float8 / 1000000.0 AS duration_ms,
      max(status_code) FILTER (WHERE parent_span_id IS NULL OR parent_span_id = '') AS status_code,
      max(status_message) FILTER (WHERE parent_span_id IS NULL OR parent_span_id = '') AS status_message,
      array_agg(DISTINCT service_name) FILTER (WHERE service_name IS NOT NULL) AS service_set,
      count(*) AS span_count,
      count(*) FILTER (WHERE status_code IS NOT NULL AND status_code != 1) AS error_count
    FROM otel_traces
    WHERE timestamp >= NOW() - INTERVAL '7 days'
      AND trace_id IS NOT NULL
    GROUP BY trace_id
    """)

    # Create unique index on trace_id - required for REFRESH CONCURRENTLY
    execute("""
    CREATE UNIQUE INDEX IF NOT EXISTS idx_trace_summaries_trace_id
    ON otel_trace_summaries (trace_id)
    """)

    # Create index on timestamp for time-range queries (DESC for recent-first)
    execute("""
    CREATE INDEX IF NOT EXISTS idx_trace_summaries_timestamp
    ON otel_trace_summaries (timestamp DESC)
    """)

    # Create composite index for service filtering with time ordering
    execute("""
    CREATE INDEX IF NOT EXISTS idx_trace_summaries_service_timestamp
    ON otel_trace_summaries (root_service_name, timestamp DESC)
    """)

    # Do initial refresh to populate the view
    execute("REFRESH MATERIALIZED VIEW otel_trace_summaries")
  end

  def down do
    execute("DROP INDEX IF EXISTS idx_trace_summaries_service_timestamp")
    execute("DROP INDEX IF EXISTS idx_trace_summaries_timestamp")
    execute("DROP INDEX IF EXISTS idx_trace_summaries_trace_id")
    execute("DROP MATERIALIZED VIEW IF EXISTS otel_trace_summaries")
  end
end
