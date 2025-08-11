-- =================================================================
-- == Rollback Fix Trace Summaries Multiplication Issue
-- =================================================================
-- This migration rolls back the trace multiplication fix by
-- recreating the original multi-stage materialized view chain
-- from migration 9.

-- WARNING: This rollback will restore the multiplication issue!
-- Only use this if you need to debug or have alternative fixes.

-- 1. Drop the simplified materialized view
DROP VIEW IF EXISTS otel_trace_summaries_final_mv;
DROP VIEW IF EXISTS otel_trace_summaries_deduplicated;
DROP VIEW IF EXISTS otel_trace_summaries_final_v2;

-- 2. Drop the final stream (will be recreated with original structure)
DROP STREAM IF EXISTS otel_trace_summaries_final;

-- 3. Recreate the original complex multi-stage structure from migration 9
-- (This is a simplified recreation - for full restoration, re-run migration 9)

-- A. Per-span enrichment stream
CREATE STREAM IF NOT EXISTS otel_spans_enriched (
  timestamp             DateTime64(9),
  trace_id              string,
  span_id               string,
  parent_span_id        string,
  name                  string,
  kind                  int32,
  start_time_unix_nano  uint64,
  end_time_unix_nano    uint64,
  service_name          string,
  status_code           int32,
  status_message        string,
  duration_ms           float64,
  is_root               bool
) ENGINE = Stream(1, 1, rand())
PARTITION BY int_div(to_unix_timestamp(timestamp), 3600)
ORDER BY (trace_id, span_id)
SETTINGS index_granularity = 8192;

CREATE MATERIALIZED VIEW IF NOT EXISTS otel_spans_enriched_mv
INTO otel_spans_enriched AS
SELECT
  timestamp,
  trace_id,
  span_id,
  parent_span_id,
  name,
  kind,
  start_time_unix_nano,
  end_time_unix_nano,
  service_name,
  status_code,
  status_message,
  (end_time_unix_nano - start_time_unix_nano) / 1e6 AS duration_ms,
  (parent_span_id = '' OR parent_span_id = '0000000000000000' OR length(parent_span_id) = 0) AS is_root
FROM otel_traces;

-- B. Final summaries stream (original structure)
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
) ENGINE = Stream(1, 1, rand())
ORDER BY (timestamp, trace_id);

-- C. Simplified final materialized view (without all intermediate streams)
-- This creates the same multiplication issue but is simpler for rollback
CREATE MATERIALIZED VIEW IF NOT EXISTS otel_trace_summaries_final_mv
INTO otel_trace_summaries_final AS
SELECT
  min(timestamp) AS timestamp,
  trace_id,
  any_if(span_id, is_root) AS root_span_id,
  any_if(name, is_root) AS root_span_name,
  any_if(service_name, is_root) AS root_service_name,
  any_if(kind, is_root) AS root_span_kind,
  min(start_time_unix_nano) AS start_time_unix_nano,
  max(end_time_unix_nano) AS end_time_unix_nano,
  (max(end_time_unix_nano) - min(start_time_unix_nano)) / 1e6 AS duration_ms,
  count() AS span_count,
  sum(if(status_code = 2, 1, 0)) AS error_count,
  max(status_code) AS status_code,
  group_uniq_array(service_name) AS service_set
FROM otel_spans_enriched
GROUP BY trace_id;

-- 4. Recreate deduplication views
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

CREATE VIEW otel_trace_summaries_final_v2 AS 
SELECT * FROM otel_trace_summaries_deduplicated;