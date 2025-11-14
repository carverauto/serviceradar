-- =================================================================
-- == Fix Trace Summaries Unknown Services Migration
-- =================================================================
-- This migration fixes the issue where traces show as "unknown/unknown service"
-- and missing durations by recreating the materialized view with proper logic

-- Drop and recreate both the stream and materialized view
DROP VIEW IF EXISTS otel_trace_summaries_final_mv;
DROP STREAM IF EXISTS otel_trace_summaries_final;

-- Recreate the stream
CREATE STREAM IF NOT EXISTS otel_trace_summaries_final (
  timestamp             DateTime64(9),
  trace_id              string,
  root_span_id          string,
  root_span_name        string,
  root_service_name     string,
  root_span_kind        int32,
  start_time_unix_nano  uint64,
  end_time_unix_nano    uint64,
  duration_ms           float64,
  span_count            uint32,
  error_count           uint32,
  status_code           int32,
  service_set           array(string)
) ENGINE = Stream(1, rand())
ORDER BY (timestamp, trace_id);

-- Recreate the materialized view with proper defaults and direct span data
CREATE MATERIALIZED VIEW IF NOT EXISTS otel_trace_summaries_final_mv
INTO otel_trace_summaries_final AS
SELECT
  now() as timestamp,
  e.trace_id AS trace_id,
  COALESCE(null_if(r.root_span_name, ''), null_if(e.name, ''), 'unknown') AS root_span_name,
  COALESCE(null_if(r.root_service, ''), null_if(e.service_name, ''), 'unknown') AS root_service_name,
  COALESCE(null_if(r.root_span_id, ''), null_if(e.span_id, ''), 'unknown') AS root_span_id,
  COALESCE(r.root_kind, e.kind, 0) AS root_span_kind,
  e.start_time_unix_nano AS start_time_unix_nano,
  e.end_time_unix_nano AS end_time_unix_nano,
  e.duration_ms AS duration_ms,
  COALESCE(c.span_count, 1) AS span_count,
  COALESCE(ec.error_count, 0) AS error_count,
  1 AS status_code,
  COALESCE(sv.service_set, [e.service_name]) AS service_set
FROM otel_spans_enriched AS e
LEFT JOIN otel_root_spans AS r ON e.trace_id = r.trace_id
LEFT JOIN otel_trace_span_count AS c ON e.trace_id = c.trace_id
LEFT JOIN otel_trace_error_count AS ec ON e.trace_id = ec.trace_id
LEFT JOIN otel_trace_services AS sv ON e.trace_id = sv.trace_id
WHERE e.is_root = true;