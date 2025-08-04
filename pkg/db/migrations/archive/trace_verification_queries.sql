-- =================================================================
-- == Trace Enrichment Verification Queries
-- =================================================================
-- Use these queries to verify the trace enrichment implementation

-- 1. Recent traces with root, duration, status
SELECT timestamp, trace_id, root_service_name, root_span_name, duration_ms, span_count, error_count, status_code
FROM otel_trace_summaries_final
ORDER BY timestamp DESC
LIMIT 50;

-- 2. Validate components exist
SELECT * FROM otel_trace_min_start ORDER BY trace_id LIMIT 5;
SELECT * FROM otel_trace_max_end ORDER BY trace_id LIMIT 5;
SELECT * FROM otel_trace_span_count ORDER BY trace_id LIMIT 5;
SELECT * FROM otel_trace_error_count ORDER BY trace_id LIMIT 5;
SELECT * FROM otel_trace_status_max ORDER BY trace_id LIMIT 5;
SELECT * FROM otel_trace_duration ORDER BY trace_id LIMIT 5;
SELECT * FROM otel_root_spans ORDER BY trace_id LIMIT 5;
SELECT * FROM otel_trace_services ORDER BY trace_id LIMIT 5;

-- 3. Check enriched spans work correctly
SELECT trace_id, span_id, name, service_name, duration_ms, is_root
FROM otel_spans_enriched
ORDER BY timestamp DESC
LIMIT 20;

-- 4. Validate root span detection
SELECT trace_id, root_span_id, root_span_name, root_service
FROM otel_root_spans
ORDER BY trace_id DESC
LIMIT 10;

-- 5. Check duration calculations
SELECT 
    trace_id,
    duration_ms as trace_duration,
    start_time_unix_nano,
    end_time_unix_nano
FROM otel_trace_duration
WHERE duration_ms > 0
ORDER BY duration_ms DESC
LIMIT 10;

-- 6. Trace reconstruction for a specific trace
SELECT service_name, name, span_id, parent_span_id, start_time_unix_nano, end_time_unix_nano, status_code
FROM otel_traces
WHERE trace_id = 'REPLACE_WITH_ACTUAL_TRACE_ID'
ORDER BY start_time_unix_nano;

-- 7. Metrics ↔ spans correlation
SELECT m.timestamp, m.service_name, m.span_name, m.duration_ms, t.name, t.status_code
FROM otel_metrics m
JOIN otel_traces t ON m.trace_id = t.trace_id AND m.span_id = t.span_id
ORDER BY m.timestamp DESC
LIMIT 100;

-- 8. Logs ↔ spans correlation
SELECT l.timestamp, l.severity_text, l.body, t.service_name, t.name
FROM logs l
JOIN otel_traces t ON l.trace_id = t.trace_id AND l.span_id = t.span_id
WHERE l.trace_id = 'REPLACE_WITH_ACTUAL_TRACE_ID'
ORDER BY l.timestamp;

-- 9. Attribute filters (normalized)
SELECT t.service_name, t.name, a.http_method, a.http_route
FROM otel_traces t
JOIN otel_span_attrs a USING (trace_id, span_id)
WHERE a.http_method = 'GET'
ORDER BY t.timestamp DESC
LIMIT 100;

-- 10. Check for HTTP spans with normalized attributes
SELECT COUNT(*) as http_spans_count
FROM otel_span_attrs
WHERE http_method IS NOT NULL;

-- 11. Check for gRPC spans with normalized attributes
SELECT COUNT(*) as grpc_spans_count
FROM otel_span_attrs
WHERE rpc_service IS NOT NULL;

-- 12. Span tree reconstruction with edges
SELECT 
    e.trace_id,
    e.parent_span_id,
    e.child_span_id,
    e.child_name,
    e.child_service
FROM otel_span_edges e
WHERE e.trace_id = 'REPLACE_WITH_ACTUAL_TRACE_ID'
ORDER BY e.parent_span_id, e.child_span_id;

-- 13. Performance analysis - slowest traces
SELECT 
    trace_id,
    root_service_name,
    root_span_name,
    duration_ms,
    span_count,
    error_count
FROM otel_trace_summaries_final
WHERE duration_ms > 1000  -- Traces slower than 1 second
ORDER BY duration_ms DESC
LIMIT 20;

-- 14. Service performance breakdown
SELECT 
    service_name,
    count() AS total_spans,
    avg(duration_ms) AS avg_duration_ms,
    quantile(0.95)(duration_ms) AS p95_duration_ms,
    sum(if(is_root, 1, 0)) AS root_spans_count
FROM otel_spans_enriched
WHERE timestamp >= now() - INTERVAL 1 HOUR
GROUP BY service_name
ORDER BY avg_duration_ms DESC;

-- 15. Root span distribution by service
SELECT 
    root_service_name,
    count() AS root_span_count,
    avg(duration_ms) AS avg_trace_duration_ms,
    max(duration_ms) AS max_trace_duration_ms
FROM otel_trace_summaries_final
WHERE timestamp >= now() - INTERVAL 1 HOUR
GROUP BY root_service_name
ORDER BY root_span_count DESC;

-- 16. Error rate by service
SELECT 
    root_service_name,
    count() AS total_traces,
    sum(error_count) AS total_errors,
    (sum(error_count) * 100.0 / count()) AS error_rate_percent
FROM otel_trace_summaries_final
WHERE timestamp >= now() - INTERVAL 1 HOUR
GROUP BY root_service_name
HAVING total_traces > 10  -- Only services with meaningful volume
ORDER BY error_rate_percent DESC;

-- 17. Count materialized view data
SELECT 'otel_spans_enriched' as table_name, count() as row_count FROM otel_spans_enriched
UNION ALL
SELECT 'otel_trace_min_start' as table_name, count() as row_count FROM otel_trace_min_start
UNION ALL
SELECT 'otel_trace_max_end' as table_name, count() as row_count FROM otel_trace_max_end
UNION ALL
SELECT 'otel_trace_span_count' as table_name, count() as row_count FROM otel_trace_span_count
UNION ALL
SELECT 'otel_trace_error_count' as table_name, count() as row_count FROM otel_trace_error_count
UNION ALL
SELECT 'otel_trace_status_max' as table_name, count() as row_count FROM otel_trace_status_max
UNION ALL
SELECT 'otel_trace_duration' as table_name, count() as row_count FROM otel_trace_duration
UNION ALL
SELECT 'otel_root_spans' as table_name, count() as row_count FROM otel_root_spans
UNION ALL
SELECT 'otel_trace_services' as table_name, count() as row_count FROM otel_trace_services
UNION ALL
SELECT 'otel_trace_summaries_final' as table_name, count() as row_count FROM otel_trace_summaries_final
UNION ALL
SELECT 'otel_span_attrs' as table_name, count() as row_count FROM otel_span_attrs;

-- 18. Check data freshness
SELECT 
    'otel_traces' as source_table,
    min(timestamp) as earliest,
    max(timestamp) as latest,
    count() as total_rows
FROM otel_traces
UNION ALL
SELECT 
    'otel_trace_summaries_final' as derived_table,
    min(timestamp) as earliest,
    max(timestamp) as latest,
    count() as total_rows
FROM otel_trace_summaries_final;