-- =================================================================
-- == Fix Trace Summaries Unknown Services Migration
-- =================================================================
-- This migration fixes the issue where traces show as "unknown/unknown service"
-- by modifying the materialized view to use proper default values instead of empty strings

-- Drop and recreate the materialized view with proper defaults
DROP VIEW IF EXISTS otel_trace_summaries_final_mv;

CREATE MATERIALIZED VIEW IF NOT EXISTS otel_trace_summaries_final_mv
INTO otel_trace_summaries_final AS
SELECT
  now() as timestamp,
  e.trace_id AS trace_id,
  COALESCE(null_if(r.root_span_name, ''), null_if(e.name, ''), 'unknown') AS root_span_name,
  COALESCE(null_if(r.root_service, ''), null_if(e.service_name, ''), 'unknown') AS root_service_name,
  COALESCE(null_if(r.root_span_id, ''), null_if(e.span_id, ''), 'unknown') AS root_span_id,
  COALESCE(r.root_kind, e.kind, 0) AS root_span_kind,
  COALESCE(d.start_time_unix_nano, e.start_time_unix_nano) AS start_time_unix_nano,
  COALESCE(d.end_time_unix_nano, e.end_time_unix_nano) AS end_time_unix_nano,
  COALESCE(d.duration_ms, e.duration_ms) AS duration_ms,
  COALESCE(c.span_count, 1) AS span_count,
  COALESCE(ec.error_count, 0) AS error_count,
  1 AS status_code,
  COALESCE(sv.service_set, [e.service_name]) AS service_set
FROM otel_spans_enriched AS e
LEFT JOIN otel_trace_duration AS d ON e.trace_id = d.trace_id
LEFT JOIN otel_root_spans AS r ON e.trace_id = r.trace_id
LEFT JOIN otel_trace_span_count AS c ON e.trace_id = c.trace_id
LEFT JOIN otel_trace_error_count AS ec ON e.trace_id = ec.trace_id
LEFT JOIN otel_trace_services AS sv ON e.trace_id = sv.trace_id
WHERE e.is_root = true;