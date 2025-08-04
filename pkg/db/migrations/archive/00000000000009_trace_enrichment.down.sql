-- =================================================================
-- == Rollback Trace Enrichment Migration
-- =================================================================
-- This rollback removes all trace enrichment streams and materialized views

-- Drop materialized views first (in reverse dependency order)
DROP VIEW IF EXISTS otel_span_edges_mv;
DROP VIEW IF EXISTS otel_trace_summaries_final_mv;
DROP VIEW IF EXISTS otel_trace_duration_mv;
DROP VIEW IF EXISTS otel_trace_min_ts_mv;
DROP VIEW IF EXISTS otel_trace_services_mv;
DROP VIEW IF EXISTS otel_trace_status_max_mv;
DROP VIEW IF EXISTS otel_trace_error_count_mv;
DROP VIEW IF EXISTS otel_trace_span_count_mv;
DROP VIEW IF EXISTS otel_trace_max_end_mv;
DROP VIEW IF EXISTS otel_trace_min_start_mv;
DROP VIEW IF EXISTS otel_root_spans_mv;
DROP VIEW IF EXISTS otel_spans_enriched_mv;

-- Drop streams (in reverse dependency order)
DROP STREAM IF EXISTS otel_span_edges;
DROP STREAM IF EXISTS otel_trace_summaries_final;
DROP STREAM IF EXISTS otel_trace_duration;
DROP STREAM IF EXISTS otel_trace_min_ts;
DROP STREAM IF EXISTS otel_trace_services;
DROP STREAM IF EXISTS otel_trace_status_max;
DROP STREAM IF EXISTS otel_trace_error_count;
DROP STREAM IF EXISTS otel_trace_span_count;
DROP STREAM IF EXISTS otel_trace_max_end;
DROP STREAM IF EXISTS otel_trace_min_start;
DROP STREAM IF EXISTS otel_root_spans;
DROP STREAM IF EXISTS otel_span_attrs;
DROP STREAM IF EXISTS otel_spans_enriched;

-- Note: This rollback does not restore the old otel_trace_summaries_mv
-- If you need to restore the old view, run:
-- CREATE MATERIALIZED VIEW IF NOT EXISTS otel_trace_summaries_mv
-- INTO otel_trace_summaries AS
-- SELECT
--   min(timestamp) AS timestamp,
--   trace_id,
--   '' AS root_span_id,
--   '' AS root_span_name,
--   0 AS root_span_kind,
--   any(service_name) AS root_service_name,
--   min(start_time_unix_nano) AS start_time_unix_nano,
--   max(end_time_unix_nano) AS end_time_unix_nano,
--   0.0 AS duration_ms,
--   1 AS status_code,
--   '' AS status_message,
--   group_uniq_array(service_name) AS service_set,
--   count() AS span_count,
--   0 AS error_count
-- FROM otel_traces
-- GROUP BY trace_id;