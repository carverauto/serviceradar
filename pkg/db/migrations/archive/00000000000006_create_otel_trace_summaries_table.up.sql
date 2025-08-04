-- =================================================================
-- == OTEL Trace Summaries Stream Migration
-- =================================================================
-- Add otel_trace_summaries stream and materialized view for fast trace discovery

-- OTEL trace summaries stream for fast trace listing/search
CREATE STREAM IF NOT EXISTS otel_trace_summaries (
    -- Core trace identifiers and metadata
    timestamp         DateTime64(9) CODEC(Delta(8), ZSTD(1)),
    trace_id          string CODEC(ZSTD(1)),
    root_span_id      string CODEC(ZSTD(1)),
    root_span_name    string CODEC(ZSTD(1)),
    root_service_name string CODEC(ZSTD(1)),
    root_span_kind    int32 CODEC(ZSTD(1)),
    
    -- Timing information
    start_time_unix_nano uint64 CODEC(Delta(8), ZSTD(1)),
    end_time_unix_nano   uint64 CODEC(Delta(8), ZSTD(1)),
    duration_ms          float64 CODEC(ZSTD(1)),
    
    -- Status and error information
    status_code       int32 CODEC(ZSTD(1)),
    status_message    string CODEC(ZSTD(1)),
    
    -- Aggregated trace metadata
    service_set       array(string) CODEC(ZSTD(1)),
    span_count        uint32 CODEC(ZSTD(1)),
    error_count       uint32 CODEC(ZSTD(1))
    
) ENGINE = Stream(1, 1, rand())
PARTITION BY int_div(to_unix_timestamp(timestamp), 3600)
ORDER BY (timestamp, trace_id)
SETTINGS index_granularity = 8192;

-- Create materialized view to populate trace summaries from otel_traces
-- Simple direct aggregation without subqueries to avoid nested aggregate issues  
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