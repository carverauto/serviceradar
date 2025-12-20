-- Rollback: Remove trace summaries materialized view

-- Remove pg_cron job if it exists
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
        PERFORM cron.unschedule('refresh_otel_trace_summaries');
    END IF;
EXCEPTION
    WHEN undefined_function THEN
        -- pg_cron not available, nothing to unschedule
        NULL;
    WHEN undefined_object THEN
        -- Job doesn't exist
        NULL;
END $$;

-- Drop indexes (will be dropped with MV, but explicit for clarity)
DROP INDEX IF EXISTS idx_trace_summaries_service_timestamp;
DROP INDEX IF EXISTS idx_trace_summaries_timestamp;
DROP INDEX IF EXISTS idx_trace_summaries_trace_id;

-- Drop the materialized view
DROP MATERIALIZED VIEW IF EXISTS otel_trace_summaries;
