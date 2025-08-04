-- =================================================================
-- == Drop Old Trace Summaries Materialized View
-- =================================================================
-- This migration drops the old otel_trace_summaries_mv that was
-- creating duplicate/incorrect entries after the new trace enrichment
-- system was implemented in migration 9.
--
-- The new system uses otel_trace_summaries_final as the main table
-- for trace summaries, populated through a more sophisticated
-- multi-stage materialized view pipeline.

-- Drop the old materialized view that's causing duplicate entries
DROP VIEW IF EXISTS otel_trace_summaries_mv;

-- Note: We're keeping the otel_trace_summaries table for now
-- in case there's historical data that needs to be preserved.
-- It can be dropped in a future migration after verification.