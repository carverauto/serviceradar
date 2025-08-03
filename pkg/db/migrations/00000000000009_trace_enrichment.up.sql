-- =================================================================
-- == Trace Enrichment Migration - Split Derivations for Streaming
-- =================================================================
-- This migration implements a staged approach to trace processing:
-- 1. Per-span enrichment (projection, no aggregation)
-- 2. Per-trace stats via single GROUP BY MVs  
-- 3. Root span extraction via filter-only MV
-- 4. Final join-only MV for UI convenience
-- 5. Normalized attributes for fast filtering

-- A. Per-span enrichment (projection, no aggregation)
-- Purpose: compute span duration and is_root once; feed other MVs
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

-- B. Root span extraction (filter-only, no aggregation)
CREATE STREAM IF NOT EXISTS otel_root_spans (
  trace_id       string,
  root_span_id   string,
  root_span_name string,
  root_kind      int32,
  root_service   string
) ENGINE = Stream(1, 1, rand())
ORDER BY (trace_id);

CREATE MATERIALIZED VIEW IF NOT EXISTS otel_root_spans_mv
INTO otel_root_spans AS
SELECT
  trace_id,
  span_id  AS root_span_id,
  name     AS root_span_name,
  kind     AS root_kind,
  service_name AS root_service
FROM otel_spans_enriched
WHERE is_root;

-- C. Per-trace scalar aggregates (split to avoid nested aggregates)
-- C1. Min start time per trace
CREATE STREAM IF NOT EXISTS otel_trace_min_start (
  trace_id              string,
  start_time_unix_nano  uint64
) ENGINE = Stream(1, 1, rand())
ORDER BY (trace_id);

CREATE MATERIALIZED VIEW IF NOT EXISTS otel_trace_min_start_mv
INTO otel_trace_min_start AS
SELECT
  trace_id,
  min(start_time_unix_nano) AS start_time_unix_nano
FROM otel_spans_enriched
GROUP BY trace_id;

-- C2. Max end time per trace
CREATE STREAM IF NOT EXISTS otel_trace_max_end (
  trace_id            string,
  end_time_unix_nano  uint64
) ENGINE = Stream(1, 1, rand())
ORDER BY (trace_id);

CREATE MATERIALIZED VIEW IF NOT EXISTS otel_trace_max_end_mv
INTO otel_trace_max_end AS
SELECT
  trace_id,
  max(end_time_unix_nano) AS end_time_unix_nano
FROM otel_spans_enriched
GROUP BY trace_id;

-- C3. Span count per trace
CREATE STREAM IF NOT EXISTS otel_trace_span_count (
  trace_id    string,
  span_count  uint32
) ENGINE = Stream(1, 1, rand())
ORDER BY (trace_id);

CREATE MATERIALIZED VIEW IF NOT EXISTS otel_trace_span_count_mv
INTO otel_trace_span_count AS
SELECT
  trace_id,
  count() AS span_count
FROM otel_spans_enriched
GROUP BY trace_id;

-- C4. Error count per trace (using sum(if(...)) instead of countIf)
CREATE STREAM IF NOT EXISTS otel_trace_error_count (
  trace_id     string,
  error_count  uint32
) ENGINE = Stream(1, 1, rand())
ORDER BY (trace_id);

CREATE MATERIALIZED VIEW IF NOT EXISTS otel_trace_error_count_mv
INTO otel_trace_error_count AS
SELECT
  trace_id,
  sum(if(status_code = 2, 1, 0)) AS error_count
FROM otel_spans_enriched
GROUP BY trace_id;

-- C5. Max status code per trace
CREATE STREAM IF NOT EXISTS otel_trace_status_max (
  trace_id        string,
  status_code_max int32
) ENGINE = Stream(1, 1, rand())
ORDER BY (trace_id);

CREATE MATERIALIZED VIEW IF NOT EXISTS otel_trace_status_max_mv
INTO otel_trace_status_max AS
SELECT
  trace_id,
  max(status_code) AS status_code_max
FROM otel_spans_enriched
GROUP BY trace_id;

-- D. Per-trace service set (single GROUP BY)
CREATE STREAM IF NOT EXISTS otel_trace_services (
  trace_id     string,
  service_set  array(string)
) ENGINE = Stream(1, 1, rand())
ORDER BY (trace_id);

CREATE MATERIALIZED VIEW IF NOT EXISTS otel_trace_services_mv
INTO otel_trace_services AS
SELECT
  trace_id,
  group_uniq_array(service_name) AS service_set
FROM otel_spans_enriched
GROUP BY trace_id;

-- E. Per-trace first timestamp (single GROUP BY)
-- Helps order the final summaries by a consistent timestamp
CREATE STREAM IF NOT EXISTS otel_trace_min_ts (
  trace_id  string,
  timestamp DateTime64(9)
) ENGINE = Stream(1, 1, rand())
ORDER BY (trace_id);

CREATE MATERIALIZED VIEW IF NOT EXISTS otel_trace_min_ts_mv
INTO otel_trace_min_ts AS
SELECT
  trace_id,
  min(timestamp) AS timestamp
FROM otel_spans_enriched
GROUP BY trace_id;

-- F. Duration per trace (join-only MV, use ON instead of USING)
-- Compute duration_ms with a join-only MV that has no aggregates
CREATE STREAM IF NOT EXISTS otel_trace_duration (
  trace_id              string,
  start_time_unix_nano  uint64,
  end_time_unix_nano    uint64,
  duration_ms           float64
) ENGINE = Stream(1, 1, rand())
ORDER BY (trace_id);

CREATE MATERIALIZED VIEW IF NOT EXISTS otel_trace_duration_mv
INTO otel_trace_duration AS
SELECT
  s.trace_id AS trace_id,
  s.start_time_unix_nano AS start_time_unix_nano,
  e.end_time_unix_nano AS end_time_unix_nano,
  (e.end_time_unix_nano - s.start_time_unix_nano) / 1e6 AS duration_ms
FROM otel_trace_min_start AS s
JOIN otel_trace_max_end AS e ON s.trace_id = e.trace_id;

-- G. Final summaries using ON joins (avoid multiple USING)
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

CREATE MATERIALIZED VIEW IF NOT EXISTS otel_trace_summaries_final_mv
INTO otel_trace_summaries_final AS
SELECT
  t.timestamp,
  d.trace_id,
  COALESCE(r.root_span_id, '') AS root_span_id,
  COALESCE(r.root_span_name, '') AS root_span_name,
  COALESCE(r.root_service, '') AS root_service_name,
  COALESCE(r.root_kind, 0) AS root_span_kind,
  d.start_time_unix_nano,
  d.end_time_unix_nano,
  d.duration_ms,
  COALESCE(c.span_count, 0) AS span_count,
  COALESCE(ec.error_count, 0) AS error_count,
  COALESCE(sm.status_code_max, 1) AS status_code,
  COALESCE(sv.service_set, []) AS service_set
FROM otel_trace_duration AS d
LEFT JOIN otel_trace_min_ts AS t ON d.trace_id = t.trace_id
LEFT JOIN otel_root_spans AS r ON d.trace_id = r.trace_id
LEFT JOIN otel_trace_span_count AS c ON d.trace_id = c.trace_id
LEFT JOIN otel_trace_error_count AS ec ON d.trace_id = ec.trace_id
LEFT JOIN otel_trace_status_max AS sm ON d.trace_id = sm.trace_id
LEFT JOIN otel_trace_services AS sv ON d.trace_id = sv.trace_id;

-- H. Attribute normalization stream (for span filters)
-- Populated by db-event-writer at ingestion. No parsing in MVs.
CREATE STREAM IF NOT EXISTS otel_span_attrs (
  trace_id string,
  span_id  string,
  http_method nullable(string),
  http_route  nullable(string),
  http_status_code nullable(string),
  rpc_service nullable(string),
  rpc_method  nullable(string),
  rpc_grpc_status_code nullable(string)
) ENGINE = Stream(1, 1, rand())
ORDER BY (trace_id, span_id);

-- I. Optional: edges stream (tree expansion)
CREATE STREAM IF NOT EXISTS otel_span_edges (
  trace_id       string,
  parent_span_id string,
  child_span_id  string,
  child_name     string,
  child_service  string
) ENGINE = Stream(1, 1, rand())
ORDER BY (trace_id, parent_span_id);

CREATE MATERIALIZED VIEW IF NOT EXISTS otel_span_edges_mv
INTO otel_span_edges AS
SELECT
  trace_id,
  parent_span_id,
  span_id AS child_span_id,
  name    AS child_name,
  service_name AS child_service
FROM otel_traces
WHERE parent_span_id != '' AND length(parent_span_id) > 0;

-- J. Performance indexes
-- Add minmax indexes for time-filtered queries
ALTER STREAM otel_spans_enriched ADD INDEX idx_timestamp timestamp TYPE minmax GRANULARITY 1;
ALTER STREAM otel_trace_summaries_final ADD INDEX idx_timestamp timestamp TYPE minmax GRANULARITY 1;
ALTER STREAM otel_trace_summaries_final ADD INDEX idx_duration duration_ms TYPE minmax GRANULARITY 1;

-- Keep existing bloom filters on trace_id and service_name
-- (These should already exist from previous migrations)