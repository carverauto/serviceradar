# OpenTelemetry Query Reference for ServiceRadar

This document provides SQL queries and helpers for working with OpenTelemetry traces in ServiceRadar.

## Available Streams

ServiceRadar provides multiple pre-enriched streams for trace analysis:

- `otel_traces` - Raw trace data
- `otel_spans_enriched` - Enriched spans with calculated durations and root detection
- `otel_trace_summaries_final` - Pre-aggregated trace summaries (recommended for queries)
- `otel_root_spans` - Root spans only

## Using Pre-Aggregated Summaries (Recommended)

For most queries, use the `otel_trace_summaries_final` stream which provides pre-calculated metrics:

```sql
-- Get trace overview using pre-aggregated data
SELECT 
    trace_id,
    root_span_id,
    root_span_name,
    root_service_name,
    duration_ms,              -- Pre-calculated total trace duration
    span_count,               -- Pre-calculated span count
    error_count,              -- Pre-calculated error count
    service_set               -- Array of all services in the trace
FROM otel_trace_summaries_final
WHERE trace_id = 'your_trace_id';
```

## Individual Span Duration Calculation

For detailed span analysis, use the enriched spans stream:

```sql
-- Calculate duration for individual spans (using enriched stream)
SELECT 
    trace_id,
    span_id,
    name,
    service_name,
    start_time_unix_nano,
    end_time_unix_nano,
    duration_ms,              -- Pre-calculated from enriched stream
    is_root                   -- Pre-calculated root detection
FROM otel_spans_enriched
WHERE trace_id = 'your_trace_id'
ORDER BY start_time_unix_nano;
```

## SRQL Queries

Use ServiceRadar Query Language (SRQL) for simplified trace queries:

```
# Find slow traces
show otel_trace_summaries where duration_ms > 1000

# Find traces with errors
show otel_trace_summaries where error_count > 0

# Find traces for specific service
show otel_trace_summaries where root_service_name = 'serviceradar-poller'

# Get detailed spans for a trace
show otel_spans_enriched where trace_id = 'your_trace_id'
```

## Legacy Query-Time Calculations (Not Recommended)

For backwards compatibility, you can still calculate durations at query time:

```sql
-- Get trace summary with query-time calculations (DEPRECATED - use summaries instead)
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
    sum(if(status_code = 2, 1, 0)) AS error_count,  -- Use sum(if) instead of count_if
    max(status_code) AS worst_status_code
    
FROM otel_traces 
WHERE trace_id = 'your_trace_id'
GROUP BY trace_id;
```

## Performance Analysis Queries

### Top Slowest Traces (Using Pre-Aggregated Data)
```sql
SELECT 
    trace_id,
    root_service_name,
    root_span_name,
    duration_ms,
    span_count,
    error_count
FROM otel_trace_summaries_final
WHERE timestamp >= now() - INTERVAL 1 HOUR
  AND duration_ms > 1000  -- Traces slower than 1 second
ORDER BY duration_ms DESC
LIMIT 20;
```

### Service Performance Breakdown (Using Enriched Spans)
```sql
SELECT 
    service_name,
    count() AS total_spans,
    avg(duration_ms) AS avg_duration_ms,
    quantile(0.95)(duration_ms) AS p95_duration_ms,
    sum(if(status_code = 2, 1, 0)) AS error_count  -- Use sum(if) instead of count_if
FROM otel_spans_enriched
WHERE timestamp >= now() - INTERVAL 1 HOUR
GROUP BY service_name
ORDER BY avg_duration_ms DESC;
```

### Error Analysis
```sql
-- Find traces with the most errors
SELECT 
    trace_id,
    root_service_name,
    root_span_name,
    duration_ms,
    error_count,
    span_count
FROM otel_trace_summaries_final
WHERE timestamp >= now() - INTERVAL 1 HOUR
  AND error_count > 0
ORDER BY error_count DESC, duration_ms DESC
LIMIT 20;
```

## Backend API Implementation

When implementing these queries in your backend API:

1. **For trace overviews**: Use `otel_trace_summaries_final` for fast aggregated data
2. **For span details**: Use `otel_spans_enriched` for individual span analysis
3. **For dashboards**: Use pre-aggregated streams for better performance
4. **For real-time monitoring**: Query the materialized view streams directly

## Example Backend Function (Go)

```go
func (api *API) GetTraceSummary(traceID string) (*TraceSummary, error) {
    query := `
        SELECT 
            trace_id,
            root_span_id,
            root_span_name,
            root_service_name,
            duration_ms,
            span_count,
            error_count,
            service_set
        FROM otel_trace_summaries_final
        WHERE trace_id = ?
    `
    
    var summary TraceSummary
    err := api.db.QueryRow(query, traceID).Scan(
        &summary.TraceID, &summary.RootSpanID, &summary.RootSpanName,
        &summary.RootServiceName, &summary.DurationMs, &summary.SpanCount,
        &summary.ErrorCount, &summary.ServiceSet)
    
    return &summary, err
}

func (api *API) GetTraceSpans(traceID string) ([]EnrichedSpan, error) {
    query := `
        SELECT 
            trace_id,
            span_id,
            parent_span_id,
            name,
            service_name,
            start_time_unix_nano,
            end_time_unix_nano,
            duration_ms,
            is_root,
            status_code
        FROM otel_spans_enriched
        WHERE trace_id = ?
        ORDER BY start_time_unix_nano
    `
    
    rows, err := api.db.Query(query, traceID)
    if err != nil {
        return nil, err
    }
    defer rows.Close()
    
    var spans []EnrichedSpan
    for rows.Next() {
        var span EnrichedSpan
        err := rows.Scan(&span.TraceID, &span.SpanID, &span.ParentSpanID, 
                        &span.Name, &span.ServiceName, &span.StartTime, 
                        &span.EndTime, &span.DurationMs, &span.IsRoot, &span.StatusCode)
        if err != nil {
            return nil, err
        }
        spans = append(spans, span)
    }
    
    return spans, nil
}
```

## Migration Notes

This implementation replaces the previous query-time duration calculations with a staged materialized view approach. Key benefits:

- **Performance**: Pre-calculated durations and aggregations
- **Consistency**: Standardized trace metrics across all queries
- **Reliability**: Works within Timeplus/Proton streaming constraints
- **Scalability**: Handles high-volume trace data efficiently

The migration creates several streams:
- `otel_spans_enriched` - Individual spans with calculated durations
- `otel_trace_summaries_final` - Aggregated trace summaries
- `otel_root_spans` - Root span identification
- Supporting streams for intermediate calculations