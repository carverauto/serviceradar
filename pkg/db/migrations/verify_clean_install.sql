-- =================================================================
-- == Clean Installation Verification Queries
-- =================================================================
-- Use these queries to verify that the clean ServiceRadar installation
-- is working correctly with no trace multiplication issues.

-- 1. Verify all core streams exist
SELECT 'Stream existence check' as test_name;
SELECT 'devices' as stream_name, count() as row_count FROM devices
UNION ALL
SELECT 'device_discoveries' as stream_name, count() as row_count FROM device_discoveries
UNION ALL
SELECT 'interfaces' as stream_name, count() as row_count FROM interfaces
UNION ALL
SELECT 'services' as stream_name, count() as row_count FROM services
UNION ALL
SELECT 'logs' as stream_name, count() as row_count FROM logs
UNION ALL
SELECT 'process_metrics' as stream_name, count() as row_count FROM process_metrics
UNION ALL
SELECT 'otel_metrics' as stream_name, count() as row_count FROM otel_metrics
UNION ALL
SELECT 'otel_traces' as stream_name, count() as row_count FROM otel_traces
UNION ALL
SELECT 'otel_trace_summaries' as stream_name, count() as row_count FROM otel_trace_summaries;

-- 2. Verify UI views exist and work
SELECT 'UI Views check' as test_name;
SELECT 'otel_trace_summaries_final' as view_name, count() as row_count FROM otel_trace_summaries_final
UNION ALL
SELECT 'otel_trace_summaries_final_v2' as view_name, count() as row_count FROM otel_trace_summaries_final_v2
UNION ALL
SELECT 'otel_trace_summaries_deduplicated' as view_name, count() as row_count FROM otel_trace_summaries_deduplicated;

-- 3. Check for trace multiplication (this should be MINIMAL)
SELECT 
  'Trace multiplication check' as test_name,
  count() as total_summaries,
  count(DISTINCT trace_id) as unique_traces,
  count() - count(DISTINCT trace_id) as duplicates,
  round((count() - count(DISTINCT trace_id)) * 100.0 / count(), 2) as duplicate_percentage
FROM otel_trace_summaries;

-- 4. Verify materialized view is working (should have data if traces exist)
SELECT 
  'Materialized view check' as test_name,
  (SELECT count() FROM otel_traces) as raw_spans,
  (SELECT count(DISTINCT trace_id) FROM otel_traces) as unique_raw_traces,
  (SELECT count() FROM otel_trace_summaries) as summary_rows,
  (SELECT count(DISTINCT trace_id) FROM otel_trace_summaries) as unique_summary_traces;

-- 5. Sample trace data to verify correctness
SELECT 
  'Sample trace data' as test_name,
  trace_id,
  root_service_name,
  root_span_name,
  duration_ms,
  span_count,
  error_count
FROM otel_trace_summaries
ORDER BY timestamp DESC
LIMIT 3;

-- 6. Check indexes exist (should not error)
SELECT 'Index check' as test_name;
SHOW CREATE STREAM devices;

-- 7. Performance test - queries should be fast
SELECT 
  'Performance check - recent traces' as test_name,
  count() as traces_last_hour
FROM otel_trace_summaries
WHERE timestamp >= now() - INTERVAL 1 HOUR;

-- 8. Check that problematic old views don't exist
-- These should all error (which is good)
-- SELECT count() FROM otel_spans_enriched; -- Should fail
-- SELECT count() FROM otel_trace_min_start; -- Should fail
-- SELECT count() FROM otel_trace_summaries_final_mv; -- Should fail (it's now a materialized view, not a regular view)

-- 9. Verify root span detection
SELECT 
  'Root span detection' as test_name,
  count() as total_traces,
  sum(if(root_span_id != '', 1, 0)) as traces_with_root_spans,
  sum(if(root_service_name != '', 1, 0)) as traces_with_root_service
FROM otel_trace_summaries
WHERE trace_id != '';

-- 10. Overall health check
SELECT 
  '🚀 CLEAN INSTALLATION HEALTH CHECK' as status,
  CASE 
    WHEN (SELECT count() FROM otel_trace_summaries) = 0
    THEN '✅ READY - Clean installation successful, awaiting trace data'
    WHEN (SELECT count() FROM otel_trace_summaries) > 0 
     AND (SELECT count() - count(DISTINCT trace_id) FROM otel_trace_summaries) < (SELECT count() FROM otel_trace_summaries) * 0.05  -- Less than 5% duplicates
     AND (SELECT sum(if(root_span_id != '', 1, 0)) FROM otel_trace_summaries) > (SELECT count() FROM otel_trace_summaries) * 0.8  -- 80%+ have root spans
    THEN '✅ EXCELLENT - Clean schema working perfectly, no multiplication!'
    WHEN (SELECT count() - count(DISTINCT trace_id) FROM otel_trace_summaries) >= (SELECT count() FROM otel_trace_summaries) * 0.05
    THEN '⚠️  MULTIPLICATION DETECTED - Check OTEL collector config'
    ELSE '❌ ISSUES - Check individual test results above'
  END as result;

-- 11. Show current schema version
SELECT 'Schema version' as info, '1.0 - Clean Consolidated Schema' as version;