-- =================================================================
-- == Rollback Fix Trace Summaries Unknown Services Migration
-- =================================================================

-- This rollback restores the original broken materialized view
-- Note: This will bring back the "unknown service" and missing duration issues

DROP VIEW IF EXISTS otel_trace_summaries_final_mv;

-- Note: We don't recreate the stream since it should already exist from the original migration
-- If needed, the stream definition from migration 00000000000009 should be used

CREATE MATERIALIZED VIEW IF NOT EXISTS otel_trace_summaries_final_mv
INTO otel_trace_summaries_final AS
SELECT
  now() as timestamp,
  d.trace_id,
  COALESCE(r.root_span_id, '') AS root_span_id,
  COALESCE(r.root_span_name, '') AS root_span_name,
  COALESCE(r.root_service, '') AS root_service_name,
  COALESCE(r.root_kind, 0) AS root_span_kind,
  d.start_time_unix_nano,
  d.end_time_unix_nano,
  d.duration_ms,
  COALESCE(c.span_count, 1) AS span_count,
  COALESCE(ec.error_count, 0) AS error_count,
  1 AS status_code,
  COALESCE(sv.service_set, ['']) AS service_set
FROM otel_trace_duration AS d
LEFT JOIN otel_root_spans AS r ON d.trace_id = r.trace_id
LEFT JOIN otel_trace_span_count AS c ON d.trace_id = c.trace_id
LEFT JOIN otel_trace_error_count AS ec ON d.trace_id = ec.trace_id
LEFT JOIN otel_trace_services AS sv ON d.trace_id = sv.trace_id;