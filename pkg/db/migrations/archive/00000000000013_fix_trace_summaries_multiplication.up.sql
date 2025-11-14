-- =================================================================
-- == Fix Trace Summaries Multiplication Issue
-- =================================================================
-- This migration fixes the trace explosion caused by the complex
-- multi-stage materialized view chain in migration 9. The chain
-- was creating multiple entries for each trace due to intermediate
-- views feeding into each other.
--
-- Solution: Drop all intermediate materialized views and streams,
-- then create a single efficient materialized view directly from
-- otel_traces to otel_trace_summaries_final.

-- 1. Drop dependent views first (in correct dependency order)
-- Drop UI views that depend on otel_trace_summaries_final
DROP VIEW IF EXISTS otel_trace_summaries_final_v2;
DROP VIEW IF EXISTS otel_trace_summaries_deduplicated;

-- Drop final summary view
DROP VIEW IF EXISTS otel_trace_summaries_final_mv;

-- Drop intermediate join views
DROP VIEW IF EXISTS otel_trace_duration_mv;

-- Drop individual aggregation views
DROP VIEW IF EXISTS otel_trace_min_ts_mv;
DROP VIEW IF EXISTS otel_trace_services_mv;
DROP VIEW IF EXISTS otel_trace_status_max_mv;
DROP VIEW IF EXISTS otel_trace_error_count_mv;
DROP VIEW IF EXISTS otel_trace_span_count_mv;
DROP VIEW IF EXISTS otel_trace_max_end_mv;
DROP VIEW IF EXISTS otel_trace_min_start_mv;

-- Drop enrichment and extraction views
DROP VIEW IF EXISTS otel_root_spans_mv;
DROP VIEW IF EXISTS otel_spans_enriched_mv;

-- Drop edge view
DROP VIEW IF EXISTS otel_span_edges_mv;

-- 2. Now drop intermediate streams (safe after views are gone)
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
DROP STREAM IF EXISTS otel_spans_enriched;
DROP STREAM IF EXISTS otel_span_edges;

-- 3. Recreate the final summaries stream (keeping same schema for compatibility)
CREATE STREAM IF NOT EXISTS otel_trace_summaries_final (
  timestamp             DateTime64(9) CODEC(Delta(8), ZSTD(1)),
  trace_id              string CODEC(ZSTD(1)),
  root_span_id          string CODEC(ZSTD(1)),
  root_span_name        string CODEC(ZSTD(1)),
  root_service_name     string CODEC(ZSTD(1)),
  root_span_kind        int32 CODEC(ZSTD(1)),
  start_time_unix_nano  uint64 CODEC(Delta(8), ZSTD(1)),
  end_time_unix_nano    uint64 CODEC(Delta(8), ZSTD(1)),
  duration_ms           float64 CODEC(ZSTD(1)),
  span_count            uint32 CODEC(ZSTD(1)),
  error_count           uint32 CODEC(ZSTD(1)),
  status_code           int32 CODEC(ZSTD(1)),
  service_set           array(string) CODEC(ZSTD(1))
) ENGINE = Stream(1, rand())
PARTITION BY int_div(to_unix_timestamp(timestamp), 3600)
ORDER BY (timestamp, trace_id)
SETTINGS index_granularity = 8192;

-- 4. Create single efficient materialized view that does everything in one step
-- This eliminates the multiplication issue by avoiding intermediate views
CREATE MATERIALIZED VIEW IF NOT EXISTS otel_trace_summaries_final_mv
INTO otel_trace_summaries_final AS
SELECT
  min(timestamp) AS timestamp,
  trace_id,
  
  -- Root span detection and extraction
  any_if(span_id, parent_span_id = '' OR parent_span_id = '0000000000000000' OR length(parent_span_id) = 0) AS root_span_id,
  any_if(name, parent_span_id = '' OR parent_span_id = '0000000000000000' OR length(parent_span_id) = 0) AS root_span_name,
  any_if(service_name, parent_span_id = '' OR parent_span_id = '0000000000000000' OR length(parent_span_id) = 0) AS root_service_name,
  any_if(kind, parent_span_id = '' OR parent_span_id = '0000000000000000' OR length(parent_span_id) = 0) AS root_span_kind,
  
  -- Timing calculations
  min(start_time_unix_nano) AS start_time_unix_nano,
  max(end_time_unix_nano) AS end_time_unix_nano,
  (max(end_time_unix_nano) - min(start_time_unix_nano)) / 1e6 AS duration_ms,
  
  -- Aggregations
  count() AS span_count,
  sum(if(status_code = 2, 1, 0)) AS error_count,
  max(status_code) AS status_code,
  group_uniq_array(service_name) AS service_set
  
FROM otel_traces
GROUP BY trace_id;

-- 5. Add performance indexes
ALTER STREAM otel_trace_summaries_final 
  ADD INDEX IF NOT EXISTS idx_timestamp timestamp TYPE minmax GRANULARITY 1;
  
ALTER STREAM otel_trace_summaries_final 
  ADD INDEX IF NOT EXISTS idx_duration duration_ms TYPE minmax GRANULARITY 1;

-- 6. Keep the attribute normalization stream - it's not causing multiplication
-- (otel_span_attrs stream remains unchanged)

-- 7. Update the deduplicated view to work with the new simplified structure
-- The deduplication should now be much less necessary, but keep it for safety
DROP VIEW IF EXISTS otel_trace_summaries_deduplicated;
DROP VIEW IF EXISTS otel_trace_summaries_final_v2;

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

-- Create the UI alias
CREATE VIEW otel_trace_summaries_final_v2 AS 
SELECT * FROM otel_trace_summaries_deduplicated;