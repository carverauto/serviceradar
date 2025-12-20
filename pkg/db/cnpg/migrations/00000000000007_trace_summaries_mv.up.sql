-- Migration: Trace summaries materialized view
-- This migration creates a materialized view that pre-aggregates trace data
-- by trace_id for fast dashboard queries. Refreshed periodically via pg_cron.

-- ============================================================================
-- otel_trace_summaries materialized view
-- Pre-computes trace-level aggregations from span data
-- ============================================================================
CREATE MATERIALIZED VIEW IF NOT EXISTS otel_trace_summaries AS
SELECT
    trace_id,
    max(timestamp) AS timestamp,
    max(span_id) FILTER (WHERE coalesce(parent_span_id, '') = '') AS root_span_id,
    max(name) FILTER (WHERE coalesce(parent_span_id, '') = '') AS root_span_name,
    max(service_name) FILTER (WHERE coalesce(parent_span_id, '') = '') AS root_service_name,
    max(kind) FILTER (WHERE coalesce(parent_span_id, '') = '') AS root_span_kind,
    min(start_time_unix_nano) AS start_time_unix_nano,
    max(end_time_unix_nano) AS end_time_unix_nano,
    greatest(0, coalesce(
        (max(end_time_unix_nano) - min(start_time_unix_nano))::double precision / 1000000.0,
        0
    )) AS duration_ms,
    max(status_code) FILTER (WHERE coalesce(parent_span_id, '') = '') AS status_code,
    max(status_message) FILTER (WHERE coalesce(parent_span_id, '') = '') AS status_message,
    array_agg(DISTINCT service_name) FILTER (WHERE service_name IS NOT NULL) AS service_set,
    count(*) AS span_count,
    sum(CASE WHEN coalesce(status_code, 0) != 1 THEN 1 ELSE 0 END)::bigint AS error_count
FROM otel_traces
WHERE timestamp > NOW() - INTERVAL '7 days'
  AND trace_id IS NOT NULL
GROUP BY trace_id;

-- Required for REFRESH MATERIALIZED VIEW CONCURRENTLY
CREATE UNIQUE INDEX IF NOT EXISTS idx_trace_summaries_trace_id
    ON otel_trace_summaries (trace_id);

-- Primary query pattern: time-ordered listing
CREATE INDEX IF NOT EXISTS idx_trace_summaries_timestamp
    ON otel_trace_summaries (timestamp DESC);

-- Common filter: by service name
CREATE INDEX IF NOT EXISTS idx_trace_summaries_service_timestamp
    ON otel_trace_summaries (root_service_name, timestamp DESC);

-- ============================================================================
-- pg_cron refresh job (if pg_cron is available)
-- Refreshes the MV every 2 minutes using CONCURRENTLY to avoid blocking reads
-- ============================================================================
DO $$
BEGIN
    -- Check if pg_cron extension is available
    IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
        -- Schedule refresh every 2 minutes
        PERFORM cron.schedule(
            'refresh_otel_trace_summaries',
            '*/2 * * * *',
            'REFRESH MATERIALIZED VIEW CONCURRENTLY otel_trace_summaries'
        );
        RAISE NOTICE 'pg_cron job scheduled for otel_trace_summaries refresh';
    ELSE
        RAISE NOTICE 'pg_cron not available - manual refresh required for otel_trace_summaries';
    END IF;
END $$;

-- ============================================================================
-- Role grants
-- ============================================================================
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'spire') THEN
        GRANT SELECT ON TABLE otel_trace_summaries TO spire;
    END IF;
END $$;

COMMENT ON MATERIALIZED VIEW otel_trace_summaries IS
'Pre-computed trace summaries aggregated by trace_id for fast dashboard queries.
Rolling 7-day window. Refreshed every 2 minutes via pg_cron (if available).
Use REFRESH MATERIALIZED VIEW CONCURRENTLY otel_trace_summaries for manual refresh.';
