-- =================================================================
-- == Trace Enrichment Backfill Scripts
-- =================================================================
-- Use these scripts to backfill historical data for trace enrichment

-- IMPORTANT: Run these in order and in manageable chunks
-- Monitor database performance during backfill operations

-- Phase 1: Backfill enriched spans (projection, no aggregation)
-- This populates otel_spans_enriched from existing otel_traces data
INSERT INTO otel_spans_enriched
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
FROM otel_traces
WHERE timestamp >= '2024-01-01'  -- Adjust date range as needed
ORDER BY timestamp;

-- Phase 2: Backfill per-trace scalar aggregates
-- Populate all scalar aggregates from otel_spans_enriched

-- 2a. Min start time
INSERT INTO otel_trace_min_start
SELECT
  trace_id,
  min(start_time_unix_nano) AS start_time_unix_nano
FROM otel_spans_enriched
WHERE timestamp >= '2024-01-01'  -- Match the date range from Phase 1
GROUP BY trace_id;

-- 2b. Max end time
INSERT INTO otel_trace_max_end
SELECT
  trace_id,
  max(end_time_unix_nano) AS end_time_unix_nano
FROM otel_spans_enriched
WHERE timestamp >= '2024-01-01'
GROUP BY trace_id;

-- 2c. Span count
INSERT INTO otel_trace_span_count
SELECT
  trace_id,
  count() AS span_count
FROM otel_spans_enriched
WHERE timestamp >= '2024-01-01'
GROUP BY trace_id;

-- 2d. Error count
INSERT INTO otel_trace_error_count
SELECT
  trace_id,
  countIf(status_code = 2) AS error_count
FROM otel_spans_enriched
WHERE timestamp >= '2024-01-01'
GROUP BY trace_id;

-- 2e. Max status code
INSERT INTO otel_trace_status_max
SELECT
  trace_id,
  max(status_code) AS status_code_max
FROM otel_spans_enriched
WHERE timestamp >= '2024-01-01'
GROUP BY trace_id;

-- Phase 3: Backfill trace services (service sets)
-- This populates otel_trace_services from otel_spans_enriched
INSERT INTO otel_trace_services
SELECT
  trace_id,
  group_uniq_array(service_name) AS service_set
FROM otel_spans_enriched
WHERE timestamp >= '2024-01-01'  -- Match the date range from Phase 1
GROUP BY trace_id;

-- Phase 4: Backfill trace timestamps
-- This populates otel_trace_min_ts from otel_spans_enriched
INSERT INTO otel_trace_min_ts
SELECT
  trace_id,
  min(timestamp) AS timestamp
FROM otel_spans_enriched
WHERE timestamp >= '2024-01-01'  -- Match the date range from Phase 1
GROUP BY trace_id;

-- Phase 5: Backfill root spans (filter only)
-- This populates otel_root_spans from otel_spans_enriched
INSERT INTO otel_root_spans
SELECT
  trace_id,
  span_id  AS root_span_id,
  name     AS root_span_name,
  kind     AS root_kind,
  service_name AS root_service
FROM otel_spans_enriched
WHERE is_root = true
  AND timestamp >= '2024-01-01';  -- Match the date range from Phase 1

-- Phase 6: Backfill trace duration (join min and max)
-- This populates otel_trace_duration from pre-aggregated min/max
INSERT INTO otel_trace_duration
SELECT
  s.trace_id,
  s.start_time_unix_nano,
  e.end_time_unix_nano,
  (e.end_time_unix_nano - s.start_time_unix_nano) / 1e6 AS duration_ms
FROM otel_trace_min_start AS s
JOIN otel_trace_max_end AS e USING (trace_id)
WHERE s.trace_id IN (
  SELECT trace_id FROM otel_spans_enriched 
  WHERE timestamp >= '2024-01-01'  -- Match the date range
);

-- Phase 7: Backfill final summaries (join only)
-- This populates otel_trace_summaries_final by joining pre-aggregated data
INSERT INTO otel_trace_summaries_final
SELECT
  tsmin.timestamp,
  d.trace_id,
  r.root_span_id,
  r.root_span_name,
  r.root_service AS root_service_name,
  r.root_kind    AS root_span_kind,
  d.start_time_unix_nano,
  d.end_time_unix_nano,
  d.duration_ms,
  c.span_count,
  ec.error_count,
  sm.status_code_max AS status_code,
  sv.service_set
FROM otel_trace_duration       AS d
LEFT JOIN otel_root_spans      AS r   USING (trace_id)
LEFT JOIN otel_trace_span_count AS c  USING (trace_id)
LEFT JOIN otel_trace_error_count AS ec USING (trace_id)
LEFT JOIN otel_trace_status_max  AS sm USING (trace_id)
LEFT JOIN otel_trace_services    AS sv USING (trace_id)
LEFT JOIN otel_trace_min_ts      AS tsmin USING (trace_id)
WHERE d.trace_id IN (
  SELECT trace_id FROM otel_spans_enriched 
  WHERE timestamp >= '2024-01-01'  -- Match the date range
);

-- Phase 8: Backfill span edges (optional, for tree expansion)
-- This populates otel_span_edges from existing otel_traces
INSERT INTO otel_span_edges
SELECT
  trace_id,
  parent_span_id,
  span_id AS child_span_id,
  name    AS child_name,
  service_name AS child_service
FROM otel_traces
WHERE parent_span_id != '' 
  AND length(parent_span_id) > 0
  AND timestamp >= '2024-01-01';  -- Match the date range

-- =====================================================================
-- == Alternative: Chunked Backfill for Large Datasets
-- =====================================================================
-- If you have a very large dataset, use these chunked approaches:

-- Example: Backfill enriched spans in daily chunks
-- Replace YYYY-MM-DD with actual dates
/*
INSERT INTO otel_spans_enriched
SELECT ... FROM otel_traces
WHERE timestamp >= 'YYYY-MM-DD 00:00:00' 
  AND timestamp < 'YYYY-MM-DD 23:59:59';
*/

-- Example: Backfill by trace_id ranges (if you need very fine control)
/*
INSERT INTO otel_trace_stats
SELECT ... FROM otel_spans_enriched
WHERE trace_id >= '00000000' AND trace_id < '10000000';
*/

-- =====================================================================
-- == Verification Queries After Backfill
-- =====================================================================

-- Check row counts match between source and derived tables
SELECT 
    (SELECT count(DISTINCT trace_id) FROM otel_traces WHERE timestamp >= '2024-01-01') as original_traces,
    (SELECT count() FROM otel_trace_duration) as backfilled_trace_durations,
    (SELECT count() FROM otel_trace_summaries_final) as final_summaries;

-- Check that root spans were identified correctly
SELECT 
    count() as total_enriched_spans,
    countIf(is_root) as root_spans_in_enriched,
    (SELECT count() FROM otel_root_spans) as root_spans_table
FROM otel_spans_enriched;

-- Check data integrity - ensure no orphaned data
SELECT 
    'durations_without_summaries' as check_name,
    count() as count
FROM otel_trace_duration d
WHERE NOT EXISTS (
    SELECT 1 FROM otel_trace_summaries_final f 
    WHERE f.trace_id = d.trace_id
)
UNION ALL
SELECT 
    'summaries_without_durations' as check_name,
    count() as count
FROM otel_trace_summaries_final f
WHERE NOT EXISTS (
    SELECT 1 FROM otel_trace_duration d 
    WHERE d.trace_id = f.trace_id
);

-- =====================================================================
-- == Performance Notes
-- =====================================================================
/*
1. Run backfill during low-traffic periods
2. Monitor disk space - materialized views will increase storage usage
3. Consider running OPTIMIZE TABLE after large backfills
4. The backfill scripts process data in dependency order:
   - otel_spans_enriched (source for all others)
   - Aggregated tables (trace_stats, trace_services, trace_min_ts) 
   - Filtered tables (root_spans)
   - Final joined table (trace_summaries_final)
5. Adjust date ranges based on your data retention needs
6. For very large datasets, run in smaller time windows
*/