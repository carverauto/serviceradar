-- =================================================================
-- == Rollback: Restore Old Trace Summaries Materialized View
-- =================================================================
-- This rollback recreates the old otel_trace_summaries_mv
-- Warning: This will likely cause duplicate trace entries again!

-- Recreate the old materialized view (from migration 6)
CREATE MATERIALIZED VIEW IF NOT EXISTS otel_trace_summaries_mv
INTO otel_trace_summaries AS
SELECT
  min(timestamp) AS timestamp,
  trace_id,
  '' AS root_span_id,
  '' AS root_span_name,
  0 AS root_span_kind,
  any(service_name) AS root_service_name,
  min(start_time_unix_nano) AS start_time_unix_nano,
  max(end_time_unix_nano) AS end_time_unix_nano,
  0.0 AS duration_ms,
  1 AS status_code,
  '' AS status_message,
  group_uniq_array(service_name) AS service_set,
  count() AS span_count,
  0 AS error_count
FROM otel_traces
GROUP BY trace_id;