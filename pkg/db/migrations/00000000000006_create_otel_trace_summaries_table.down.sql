-- Drop materialized view first
DROP VIEW IF EXISTS otel_trace_summaries_mv;

-- Drop the stream
DROP STREAM IF EXISTS otel_trace_summaries;