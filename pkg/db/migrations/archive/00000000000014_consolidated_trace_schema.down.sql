-- =================================================================
-- == ROLLBACK CONSOLIDATED TRACE SCHEMA
-- =================================================================
-- This migration rolls back the consolidated trace schema.
-- WARNING: This will restore the multiplication problem!

-- Drop all created views and streams
DROP VIEW IF EXISTS otel_trace_summaries_deduplicated;
DROP VIEW IF EXISTS otel_trace_summaries_final_v2;
DROP VIEW IF EXISTS otel_trace_summaries_final;
DROP VIEW IF EXISTS otel_trace_summaries_dedup;
DROP VIEW IF EXISTS otel_trace_summaries_mv;

DROP STREAM IF EXISTS otel_span_attrs;
DROP STREAM IF EXISTS otel_trace_summaries;

-- Note: This rollback doesn't restore the original complex schema
-- If you need the original problematic schema back, you would need 
-- to re-run the original migrations 6, 9, 10, 11, 12