-- =================================================================
-- == Rollback: Remove Deduplicated Trace Summary View
-- =================================================================

DROP VIEW IF EXISTS otel_trace_summaries_final_v2;
DROP VIEW IF EXISTS otel_trace_summaries_deduplicated;