# OpenTelemetry Query-Time Duration Calculations

This document provides SQL helpers for calculating trace durations at query time.

## Individual Span Duration Calculation

```sql
-- Calculate duration for individual spans
SELECT 
    trace_id,
    span_id,
    name,
    service_name,
    start_time_unix_nano,
    end_time_unix_nano,
    -- Duration in milliseconds
    (end_time_unix_nano - start_time_unix_nano) / 1000000.0 AS duration_ms,
    -- Duration in seconds  
    (end_time_unix_nano - start_time_unix_nano) / 1000000000.0 AS duration_seconds
FROM otel_traces
WHERE trace_id = 'your_trace_id'
ORDER BY start_time_unix_nano;
```

## Trace Summary with Root Span Detection

```sql
-- Get trace summary with proper root span identification and duration
SELECT
    trace_id,
    -- Root span identification (span with empty parent_span_id)
    any_if(span_id, parent_span_id = '' OR parent_span_id IS NULL) AS root_span_id,
    any_if(name, parent_span_id = '' OR parent_span_id IS NULL) AS root_span_name,
    any_if(service_name, parent_span_id = '' OR parent_span_id IS NULL) AS root_service_name,
    
    -- Timing calculations
    min(start_time_unix_nano) AS trace_start,
    max(end_time_unix_nano) AS trace_end,
    (max(end_time_unix_nano) - min(start_time_unix_nano)) / 1000000.0 AS total_duration_ms,
    
    -- Aggregated data
    count() AS span_count,
    group_uniq_array(service_name) AS services_involved,
    count_if(status_code != 1) AS error_count,
    min(status_code) AS worst_status_code
    
FROM otel_traces 
WHERE trace_id = 'your_trace_id'
GROUP BY trace_id;
```

## Performance Analysis Queries

### Top Slowest Traces
```sql
SELECT 
    trace_id,
    any_if(service_name, parent_span_id = '' OR parent_span_id IS NULL) AS root_service,
    any_if(name, parent_span_id = '' OR parent_span_id IS NULL) AS root_operation,
    (max(end_time_unix_nano) - min(start_time_unix_nano)) / 1000000.0 AS duration_ms,
    count() AS span_count
FROM otel_traces
WHERE timestamp >= now() - INTERVAL 1 HOUR
GROUP BY trace_id
HAVING duration_ms > 1000  -- Traces slower than 1 second
ORDER BY duration_ms DESC
LIMIT 20;
```

### Service Performance Breakdown
```sql
SELECT 
    service_name,
    count() AS total_spans,
    avg((end_time_unix_nano - start_time_unix_nano) / 1000000.0) AS avg_duration_ms,
    quantile(0.95)((end_time_unix_nano - start_time_unix_nano) / 1000000.0) AS p95_duration_ms,
    count_if(status_code != 1) AS error_count
FROM otel_traces
WHERE timestamp >= now() - INTERVAL 1 HOUR
GROUP BY service_name
ORDER BY avg_duration_ms DESC;
```

## Backend API Implementation

When implementing these queries in your backend API:

1. **For individual trace queries**: Use the trace summary query to get overview
2. **For span details**: Use the individual span query with duration calculation
3. **For dashboards**: Pre-calculate durations in your API layer
4. **For performance**: Consider caching calculated durations for frequently accessed traces

## Example Backend Function (Go)

```go
func (api *API) GetTraceWithDurations(traceID string) (*TraceDetails, error) {
    query := `
        SELECT 
            trace_id,
            span_id,
            parent_span_id,
            name,
            service_name,
            start_time_unix_nano,
            end_time_unix_nano,
            (end_time_unix_nano - start_time_unix_nano) / 1000000.0 AS duration_ms,
            status_code
        FROM otel_traces 
        WHERE trace_id = ?
        ORDER BY start_time_unix_nano
    `
    
    rows, err := api.db.Query(query, traceID)
    if err != nil {
        return nil, err
    }
    defer rows.Close()
    
    var spans []SpanWithDuration
    for rows.Next() {
        var span SpanWithDuration
        err := rows.Scan(&span.TraceID, &span.SpanID, &span.ParentSpanID, 
                        &span.Name, &span.ServiceName, &span.StartTime, 
                        &span.EndTime, &span.DurationMs, &span.StatusCode)
        if err != nil {
            return nil, err
        }
        spans = append(spans, span)
    }
    
    return &TraceDetails{Spans: spans}, nil
}
```