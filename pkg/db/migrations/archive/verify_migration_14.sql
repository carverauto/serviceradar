-- =================================================================
-- == Migration 14 Verification Queries - Consolidated Schema
-- =================================================================
-- Use these queries to verify that migration 14 successfully
-- created a clean, efficient trace schema without multiplication.

-- 1. Check main trace summaries stream exists and has data
SELECT 'Main stream check' as test_name, count() as row_count 
FROM otel_trace_summaries;

-- 2. Check for trace multiplication (should be minimal)
SELECT 
  'Multiplication check' as test_name,
  count() as total_summaries,
  count(DISTINCT trace_id) as unique_traces,
  count() - count(DISTINCT trace_id) as duplicates,
  round((count() - count(DISTINCT trace_id)) * 100.0 / count(), 2) as duplicate_percentage
FROM otel_trace_summaries;

-- 3. Verify all UI views exist and work
SELECT 'otel_trace_summaries_final' as view_name, count() as row_count FROM otel_trace_summaries_final
UNION ALL
SELECT 'otel_trace_summaries_final_v2' as view_name, count() as row_count FROM otel_trace_summaries_final_v2
UNION ALL
SELECT 'otel_trace_summaries_deduplicated' as view_name, count() as row_count FROM otel_trace_summaries_deduplicated
UNION ALL
SELECT 'otel_trace_summaries_dedup' as view_name, count() as row_count FROM otel_trace_summaries_dedup;

-- 4. Compare raw traces vs summaries - should be close to 1:1 unique traces
SELECT 
  'Raw vs Summary ratio' as test_name,
  (SELECT count(DISTINCT trace_id) FROM otel_traces) as raw_unique_traces,
  (SELECT count(DISTINCT trace_id) FROM otel_trace_summaries) as summary_unique_traces,
  (SELECT count() FROM otel_trace_summaries) as total_summary_rows,
  round((SELECT count() FROM otel_trace_summaries) * 1.0 / (SELECT count(DISTINCT trace_id) FROM otel_traces), 2) as multiplication_factor;

-- 5. Verify root span detection works
SELECT 
  'Root span detection' as test_name,
  count() as total_traces,
  sum(if(root_span_id != '', 1, 0)) as traces_with_root_spans,
  sum(if(root_service_name != '', 1, 0)) as traces_with_root_service,
  round(sum(if(root_span_id != '', 1, 0)) * 100.0 / count(), 1) as root_detection_percentage
FROM otel_trace_summaries;

-- 6. Check timing calculations
SELECT 
  'Timing calculations' as test_name,
  count() as total_traces,
  sum(if(duration_ms > 0, 1, 0)) as traces_with_positive_duration,
  round(avg(duration_ms), 2) as avg_duration_ms,
  round(max(duration_ms), 2) as max_duration_ms,
  round(sum(if(duration_ms > 0, 1, 0)) * 100.0 / count(), 1) as valid_timing_percentage
FROM otel_trace_summaries;

-- 7. Verify service aggregation
SELECT 
  'Service aggregation' as test_name,
  count() as total_traces,
  sum(if(length(service_set) > 0, 1, 0)) as traces_with_services,
  round(avg(length(service_set)), 1) as avg_services_per_trace,
  max(length(service_set)) as max_services_per_trace
FROM otel_trace_summaries;

-- 8. Check span counting
SELECT 
  'Span counting' as test_name,
  count() as total_traces,
  sum(span_count) as total_spans_counted,
  round(avg(span_count), 1) as avg_spans_per_trace,
  max(span_count) as max_spans_per_trace
FROM otel_trace_summaries;

-- 9. Error tracking
SELECT 
  'Error tracking' as test_name,
  count() as total_traces,
  sum(error_count) as total_errors,
  sum(if(error_count > 0, 1, 0)) as traces_with_errors,
  round(sum(if(error_count > 0, 1, 0)) * 100.0 / count(), 1) as error_rate_percentage
FROM otel_trace_summaries;

-- 10. Recent data sample
SELECT 
  'Recent trace sample' as test_name,
  trace_id,
  root_service_name,
  root_span_name,
  duration_ms,
  span_count,
  error_count,
  length(service_set) as service_count
FROM otel_trace_summaries
ORDER BY timestamp DESC
LIMIT 5;

-- 11. Performance test - should be fast
SELECT 
  'Performance test' as test_name,
  count() as traces_last_hour,
  round(avg(duration_ms), 2) as avg_duration_last_hour
FROM otel_trace_summaries
WHERE timestamp >= now() - INTERVAL 1 HOUR;

-- 12. Check that old problematic streams/views are gone
-- These should error (which is good)
-- SELECT count() FROM otel_spans_enriched; -- Should fail
-- SELECT count() FROM otel_trace_summaries_final_mv; -- Should fail  

-- 13. Final health assessment
SELECT 
  'CONSOLIDATED SCHEMA HEALTH CHECK' as status,
  CASE 
    WHEN (SELECT count() FROM otel_trace_summaries) > 0 
     AND (SELECT count() - count(DISTINCT trace_id) FROM otel_trace_summaries) < (SELECT count() FROM otel_trace_summaries) * 0.05  -- Less than 5% duplicates
     AND (SELECT sum(if(root_span_id != '', 1, 0)) FROM otel_trace_summaries) > (SELECT count() FROM otel_trace_summaries) * 0.8  -- 80%+ have root spans
    THEN '✅ HEALTHY - Consolidated schema working correctly'
    WHEN (SELECT count() FROM otel_trace_summaries) = 0
    THEN '⚠️  EMPTY - No trace data yet (might be normal for new deployment)'
    ELSE '❌ ISSUES - Check individual test results above'
  END as result;