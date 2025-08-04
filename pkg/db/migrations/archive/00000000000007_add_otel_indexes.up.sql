-- =================================================================
-- == OTEL Indexes Migration
-- =================================================================
-- Add indexes for correlation and performance optimization

-- Indexes for otel_traces stream
ALTER STREAM otel_traces ADD INDEX trace_id_idx trace_id TYPE bloom_filter GRANULARITY 1;
ALTER STREAM otel_traces ADD INDEX service_name_idx service_name TYPE bloom_filter GRANULARITY 1;
ALTER STREAM otel_traces ADD INDEX parent_span_idx parent_span_id TYPE bloom_filter GRANULARITY 1;
ALTER STREAM otel_traces ADD INDEX span_name_idx name TYPE bloom_filter GRANULARITY 1;
ALTER STREAM otel_traces ADD INDEX status_idx status_code TYPE bloom_filter GRANULARITY 1;

-- Indexes for otel_metrics stream
ALTER STREAM otel_metrics ADD INDEX trace_id_idx trace_id TYPE bloom_filter GRANULARITY 1;
ALTER STREAM otel_metrics ADD INDEX service_name_idx service_name TYPE bloom_filter GRANULARITY 1;
ALTER STREAM otel_metrics ADD INDEX duration_idx duration_ms TYPE minmax GRANULARITY 1;
ALTER STREAM otel_metrics ADD INDEX slow_spans_idx is_slow TYPE bloom_filter GRANULARITY 1;
ALTER STREAM otel_metrics ADD INDEX http_method_idx http_method TYPE bloom_filter GRANULARITY 1;
ALTER STREAM otel_metrics ADD INDEX metric_type_idx metric_type TYPE bloom_filter GRANULARITY 1;

-- Indexes for otel_trace_summaries stream
ALTER STREAM otel_trace_summaries ADD INDEX trace_id_idx trace_id TYPE bloom_filter GRANULARITY 1;
ALTER STREAM otel_trace_summaries ADD INDEX root_service_name_idx root_service_name TYPE bloom_filter GRANULARITY 1;
ALTER STREAM otel_trace_summaries ADD INDEX duration_ms_idx duration_ms TYPE minmax GRANULARITY 1;
ALTER STREAM otel_trace_summaries ADD INDEX status_code_idx status_code TYPE bloom_filter GRANULARITY 1;

-- Add bloom filter indexes to logs stream for correlation
ALTER STREAM logs ADD INDEX trace_id_idx trace_id TYPE bloom_filter GRANULARITY 1;