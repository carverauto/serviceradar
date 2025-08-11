-- =================================================================
-- == Migration 13 Verification Queries
-- =================================================================
-- Use these queries to verify that migration 13 successfully
-- fixed the trace multiplication issue.

-- 1. Check that intermediate streams/views are gone
-- These should all return 0 rows (table/view doesn't exist)
SELECT 'Checking dropped streams/views...' as status;

-- This will error if streams still exist (which is good - means they're dropped)
-- SELECT count() FROM otel_spans_enriched;
-- SELECT count() FROM otel_trace_min_start;
-- SELECT count() FROM otel_trace_max_end;

-- 2. Verify the simplified structure exists
SELECT 'otel_trace_summaries_final' as table_name, count() as row_count 
FROM otel_trace_summaries_final;

-- 3. Check for duplicate trace_ids in final summaries
-- This should show minimal duplicates (ideally 0)
SELECT 
  'Duplicate trace check' as test_name,
  count() as total_summaries,
  count(DISTINCT trace_id) as unique_traces,
  count() - count(DISTINCT trace_id) as duplicates
FROM otel_trace_summaries_final;

-- 4. Verify deduplication view works
SELECT 
  'Deduplication view check' as test_name,
  count() as deduplicated_count
FROM otel_trace_summaries_deduplicated;

-- 5. Compare raw traces vs summaries ratio
-- Should be close to 1:1 ratio of unique traces
SELECT 
  'Raw vs Summary comparison' as test_name,
  (SELECT count(DISTINCT trace_id) FROM otel_traces) as raw_unique_traces,
  (SELECT count(DISTINCT trace_id) FROM otel_trace_summaries_final) as summary_unique_traces,
  (SELECT count() FROM otel_trace_summaries_final) as total_summary_rows;

-- 6. Check for proper root span detection
SELECT 
  'Root span detection' as test_name,
  count() as traces_with_root_spans,
  count() - sum(if(root_span_id = '', 1, 0)) as traces_with_valid_root_spans
FROM otel_trace_summaries_final
LIMIT 10;

-- 7. Verify timing calculations
SELECT 
  'Timing calculations' as test_name,
  count() as total_traces,
  sum(if(duration_ms > 0, 1, 0)) as traces_with_positive_duration,
  avg(duration_ms) as avg_duration_ms,
  max(duration_ms) as max_duration_ms
FROM otel_trace_summaries_final;

-- 8. Check service set aggregation
SELECT 
  'Service set aggregation' as test_name,
  count() as total_traces,
  sum(if(length(service_set) > 0, 1, 0)) as traces_with_services,
  avg(length(service_set)) as avg_services_per_trace
FROM otel_trace_summaries_final;

-- 9. Sample the data to verify correctness
SELECT 
  'Sample trace data' as test_name,
  trace_id,
  root_service_name,
  root_span_name,
  duration_ms,
  span_count,
  error_count,
  length(service_set) as service_count
FROM otel_trace_summaries_final
ORDER BY timestamp DESC
LIMIT 5;

-- 10. Check for schema consistency
DESCRIBE otel_trace_summaries_final;

-- 11. Performance check - query should be fast
SELECT 
  'Performance check' as test_name,
  count() as traces_last_hour
FROM otel_trace_summaries_final
WHERE timestamp >= now() - INTERVAL 1 HOUR;

-- 12. Final health check
SELECT 
  'Migration 13 Health Check' as status,
  CASE 
    WHEN (SELECT count() FROM otel_trace_summaries_final) > 0 
     AND (SELECT count() - count(DISTINCT trace_id) FROM otel_trace_summaries_final) < (SELECT count() FROM otel_trace_summaries_final) * 0.01  -- Less than 1% duplicates
    THEN 'HEALTHY - Migration successful'
    ELSE 'ISSUES DETECTED - Check previous queries'
  END as result;