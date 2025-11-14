-- =================================================================
-- == CONSOLIDATED TRACE SCHEMA - CLEAN SLATE
-- =================================================================
-- This migration consolidates and replaces all the problematic
-- trace-related migrations (6, 9, 10, 11, 12, 13) with a single
-- clean, efficient implementation that eliminates trace multiplication.
--
-- This is the ONLY trace summaries implementation going forward.

-- 1. Clean slate - drop everything trace-summary related
-- Drop in correct dependency order
DROP VIEW IF EXISTS otel_trace_summaries_final_v2;
DROP VIEW IF EXISTS otel_trace_summaries_deduplicated;
DROP VIEW IF EXISTS otel_trace_summaries_final_mv;
DROP VIEW IF EXISTS otel_trace_summaries_mv;

-- Drop all intermediate views and streams from migration 9
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
DROP VIEW IF EXISTS otel_span_edges_mv;

-- Drop all intermediate streams
DROP STREAM IF EXISTS otel_trace_summaries_final;
DROP STREAM IF EXISTS otel_trace_summaries;
DROP STREAM IF EXISTS otel_trace_duration;
DROP STREAM IF EXISTS otel_trace_min_ts;
DROP STREAM IF EXISTS otel_trace_services;
DROP STREAM IF EXISTS otel_trace_status_max;
DROP STREAM IF EXISTS otel_trace_error_count;
DROP STREAM IF EXISTS otel_trace_span_count;
DROP STREAM IF EXISTS otel_trace_max_end;
DROP STREAM IF EXISTS otel_trace_min_start;
DROP STREAM IF EXISTS otel_root_spans;
DROP STREAM IF EXISTS otel_spans_enriched;
DROP STREAM IF EXISTS otel_span_edges;

-- 2. Create the ONLY trace summaries stream we need
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
    
    -- Aggregated trace metadata
    service_set       array(string) CODEC(ZSTD(1)),
    span_count        uint32 CODEC(ZSTD(1)),
    error_count       uint32 CODEC(ZSTD(1))
    
) ENGINE = Stream(1, rand())
PARTITION BY int_div(to_unix_timestamp(timestamp), 3600)
ORDER BY (timestamp, trace_id)
SETTINGS index_granularity = 8192;

-- 3. Create the ONLY materialized view we need - simple and efficient
CREATE MATERIALIZED VIEW IF NOT EXISTS otel_trace_summaries_mv
INTO otel_trace_summaries AS
SELECT
  min(timestamp) AS timestamp,
  trace_id,
  
  -- Root span detection (find first span with no parent)
  any_if(span_id, parent_span_id = '' OR parent_span_id = '0000000000000000' OR length(parent_span_id) = 0) AS root_span_id,
  any_if(name, parent_span_id = '' OR parent_span_id = '0000000000000000' OR length(parent_span_id) = 0) AS root_span_name,
  any_if(service_name, parent_span_id = '' OR parent_span_id = '0000000000000000' OR length(parent_span_id) = 0) AS root_service_name,
  any_if(kind, parent_span_id = '' OR parent_span_id = '0000000000000000' OR length(parent_span_id) = 0) AS root_span_kind,
  
  -- Timing calculations
  min(start_time_unix_nano) AS start_time_unix_nano,
  max(end_time_unix_nano) AS end_time_unix_nano,
  (max(end_time_unix_nano) - min(start_time_unix_nano)) / 1e6 AS duration_ms,
  
  -- Status (use max to get worst status)
  max(status_code) AS status_code,
  
  -- Aggregations
  group_uniq_array(service_name) AS service_set,
  count() AS span_count,
  sum(if(status_code = 2, 1, 0)) AS error_count

FROM otel_traces
GROUP BY trace_id;

-- 4. Add performance indexes
ALTER STREAM otel_trace_summaries 
  ADD INDEX IF NOT EXISTS idx_timestamp timestamp TYPE minmax GRANULARITY 1;
  
ALTER STREAM otel_trace_summaries 
  ADD INDEX IF NOT EXISTS idx_duration duration_ms TYPE minmax GRANULARITY 1;

ALTER STREAM otel_trace_summaries 
  ADD INDEX IF NOT EXISTS idx_trace_id trace_id TYPE bloom_filter GRANULARITY 1;

ALTER STREAM otel_trace_summaries 
  ADD INDEX IF NOT EXISTS idx_service root_service_name TYPE bloom_filter GRANULARITY 1;

-- 5. Create a simple deduplication view (should be minimal with fixed MV)
CREATE VIEW IF NOT EXISTS otel_trace_summaries_dedup AS
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
FROM otel_trace_summaries
GROUP BY trace_id;

-- 6. Create UI-compatible aliases
-- Main UI view (use dedup for safety)
CREATE VIEW otel_trace_summaries_final AS 
SELECT * FROM otel_trace_summaries_dedup;

-- Alternative name for compatibility  
CREATE VIEW otel_trace_summaries_final_v2 AS 
SELECT * FROM otel_trace_summaries_dedup;

-- Keep original name working
CREATE VIEW otel_trace_summaries_deduplicated AS 
SELECT * FROM otel_trace_summaries_dedup;

-- 7. Optional: Create attribute normalization stream for filtering
-- (Only if needed by your application)
CREATE STREAM IF NOT EXISTS otel_span_attrs (
  trace_id string,
  span_id  string,
  http_method nullable(string),
  http_route  nullable(string),
  http_status_code nullable(string),
  rpc_service nullable(string),
  rpc_method  nullable(string),
  rpc_grpc_status_code nullable(string)
) ENGINE = Stream(1, rand())
ORDER BY (trace_id, span_id);