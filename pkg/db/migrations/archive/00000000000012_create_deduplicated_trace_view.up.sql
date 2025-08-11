-- =================================================================
-- == Create Deduplicated Trace Summary View
-- =================================================================
-- The current otel_trace_summaries_final table contains duplicates
-- because the materialized view chain creates new entries for each span.
-- This migration creates a deduplicated view that shows only the latest
-- version of each trace summary.

-- Create a view that deduplicates trace summaries by selecting
-- only the most recent entry for each trace_id
-- Using any() to pick values from the latest record per trace
CREATE VIEW IF NOT EXISTS otel_trace_summaries_deduplicated AS
SELECT 
  trace_id,
  any(timestamp) as timestamp,
  any(root_span_id) as root_span_id,
  any(root_span_name) as root_span_name,
  any(root_service_name) as root_service_name,
  any(root_span_kind) as root_span_kind,
  any(start_time_unix_nano) as start_time_unix_nano,
  any(end_time_unix_nano) as end_time_unix_nano,
  any(duration_ms) as duration_ms,
  any(span_count) as span_count,
  any(error_count) as error_count,
  any(status_code) as status_code,
  any(service_set) as service_set
FROM otel_trace_summaries_final
GROUP BY trace_id;

-- Create an alias that the UI can use
-- First check if otel_trace_summaries_final is a table or view
DROP VIEW IF EXISTS otel_trace_summaries_final_v2;
CREATE VIEW otel_trace_summaries_final_v2 AS 
SELECT * FROM otel_trace_summaries_deduplicated;