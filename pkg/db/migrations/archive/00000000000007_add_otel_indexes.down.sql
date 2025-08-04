-- Drop indexes from logs table
ALTER TABLE logs DROP INDEX IF EXISTS trace_id_idx;

-- Drop indexes from otel_trace_summaries table
ALTER TABLE otel_trace_summaries DROP INDEX IF EXISTS trace_id_idx;
ALTER TABLE otel_trace_summaries DROP INDEX IF EXISTS root_service_name_idx;
ALTER TABLE otel_trace_summaries DROP INDEX IF EXISTS duration_ms_idx;
ALTER TABLE otel_trace_summaries DROP INDEX IF EXISTS status_code_idx;

-- Drop indexes from otel_metrics table
ALTER TABLE otel_metrics DROP INDEX IF EXISTS trace_id_idx;
ALTER TABLE otel_metrics DROP INDEX IF EXISTS service_name_idx;
ALTER TABLE otel_metrics DROP INDEX IF EXISTS duration_idx;
ALTER TABLE otel_metrics DROP INDEX IF EXISTS slow_spans_idx;
ALTER TABLE otel_metrics DROP INDEX IF EXISTS http_method_idx;
ALTER TABLE otel_metrics DROP INDEX IF EXISTS metric_type_idx;

-- Drop indexes from otel_traces table
ALTER TABLE otel_traces DROP INDEX IF EXISTS trace_id_idx;
ALTER TABLE otel_traces DROP INDEX IF EXISTS service_name_idx;
ALTER TABLE otel_traces DROP INDEX IF EXISTS parent_span_idx;
ALTER TABLE otel_traces DROP INDEX IF EXISTS span_name_idx;
ALTER TABLE otel_traces DROP INDEX IF EXISTS status_idx;