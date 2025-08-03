# OpenTelemetry Integration with SRQL

This document outlines the implementation of OpenTelemetry (OTEL) integration with ServiceRadar Query Language (SRQL), enabling unified querying across logs, traces, and metrics for comprehensive observability.

## Overview

The OTEL integration adds support for three new entities in SRQL:
- `otel_traces` - Raw OpenTelemetry trace spans
- `otel_metrics` - Performance metrics derived from traces
- `otel_trace_summaries` - Materialized view for fast trace discovery and filtering

## Database Schema

### OTEL Traces (`otel_traces`)
Stores raw OpenTelemetry trace spans with full span details including timing, status, and attributes.

### OTEL Metrics (`otel_metrics`) 
Contains performance analytics derived from traces, optimized for span-level performance analysis.

### OTEL Trace Summaries (`otel_trace_summaries`)
Materialized view that aggregates trace-level metadata for fast trace discovery. Includes:
- Root span information
- Trace duration and timing
- Service participation
- Error counts and status

## SRQL Field Mappings

### Correlation Fields (consistent across entities)
- `trace` → `trace_id` (for cross-entity correlation)
- `span` → `span_id` (for span-level correlation)
- `service` → `service_name` / `root_service_name`

### OTEL Traces Specific Fields
- `name` → `name` (span name)
- `kind` → `kind` (span kind)
- `start` → `start_time_unix_nano`
- `end` → `end_time_unix_nano`
- `duration_ms` → computed: `(end_time_unix_nano - start_time_unix_nano) / 1e6`

### OTEL Metrics Specific Fields
- `route` → `http_route`
- `method` → `http_method`
- `status` → `http_status_code`

### OTEL Trace Summaries Specific Fields
- `duration_ms` → `duration_ms` (pre-computed)
- `status` → `status_code`
- `span_count` → `span_count`
- `errors` → `error_count`
- `root_span` → `root_span_name`

### Logs Enhancement
Added correlation fields to logs:
- `trace` → `trace_id`
- `span` → `span_id`

## Usage Examples

### Trace Discovery and Filtering

**Browse traces by service and duration:**
```sql
FIND otel_trace_summaries FROM LAST 2 HOURS 
WHERE service = 'checkout' AND duration_ms > 250 
ORDER BY timestamp DESC LIMIT 100
```

**Find error traces:**
```sql
FIND otel_trace_summaries FROM LAST 2 HOURS 
WHERE status != 1 OR errors > 0 
ORDER BY timestamp DESC
```

### Trace Details and Analysis

**Get full trace spans:**
```sql
FIND otel_traces WHERE trace = 'abc123' ORDER BY start ASC
```

**Find slow spans in a trace:**
```sql
FIND otel_traces WHERE trace = 'abc123' AND duration_ms > 100
```

### Cross-Entity Correlation

**Get logs for a specific trace:**
```sql
FIND logs WHERE trace = 'abc123' ORDER BY timestamp ASC
```

**Get metrics for a specific trace:**
```sql
FIND otel_metrics WHERE trace = 'abc123' ORDER BY timestamp ASC
```

**Find traces and their associated logs:**
```sql
STREAM SELECT t.trace_id, t.root_span_name, count(l.trace_id) as log_count
FROM otel_trace_summaries t
LEFT JOIN logs l ON t.trace_id = l.trace_id
FROM LAST 1 HOURS
GROUP BY t.trace_id, t.root_span_name
ORDER BY log_count DESC
```

### Performance Analysis

**Slow spans dashboard:**
```sql
FIND otel_metrics FROM LAST 1 HOURS 
WHERE is_slow = true AND service = 'checkout'
ORDER BY timestamp DESC LIMIT 200
```

**Service performance aggregation:**
```sql
STREAM SELECT service_name, http_route, count() AS slow_count
FROM otel_metrics
WHERE is_slow = true FROM LAST 1 HOURS
GROUP BY service_name, http_route
ORDER BY slow_count DESC
LIMIT 50
```

### Service Health Monitoring

**Error rate by service:**
```sql
STREAM SELECT root_service_name, 
  count() as total_traces,
  sum(error_count) as total_errors,
  (sum(error_count) * 100.0 / count()) as error_rate
FROM otel_trace_summaries
FROM LAST 1 HOURS
GROUP BY root_service_name
ORDER BY error_rate DESC
```

## Database Indexes

The implementation includes optimized indexes for common query patterns:

### OTEL Traces Indexes
- `trace_id` (bloom filter) - for trace correlation
- `service_name` (bloom filter) - for service filtering
- `parent_span_id` (bloom filter) - for span relationships
- `name` (bloom filter) - for span name filtering
- `status_code` (bloom filter) - for error analysis

### OTEL Metrics Indexes
- `trace_id` (bloom filter) - for correlation
- `service_name` (bloom filter) - for service filtering
- `duration_ms` (minmax) - for performance filtering
- `is_slow` (bloom filter) - for slow span analysis
- `http_method` (bloom filter) - for HTTP analysis
- `metric_type` (bloom filter) - for metric type filtering

### OTEL Trace Summaries Indexes
- `trace_id` (bloom filter) - for trace lookup
- `root_service_name` (bloom filter) - for service filtering
- `duration_ms` (minmax) - for duration-based filtering
- `status_code` (bloom filter) - for error filtering

### Enhanced Logs Index
- `trace_id` (bloom filter) - for trace correlation

## Implementation Files

### Database Migrations
- `pkg/db/migrations/00000000000006_create_otel_trace_summaries_table.up.sql`
- `pkg/db/migrations/00000000000007_add_otel_indexes.up.sql`

### SRQL Grammar
- `pkg/srql/antlr/ServiceRadarQueryLanguage.g4` - Added OTEL entities

### Models and Parsing
- `pkg/srql/models/entities.go` - Added OtelTraces, OtelMetrics, OtelTraceSummaries
- `pkg/srql/parser/visitor.go` - Added entity type mappings
- `pkg/srql/parser/translator.go` - Added table mappings, field aliases, and computed fields

### Tests
- `pkg/srql/srql_test.go` - Added comprehensive OTEL entity tests

## Next Steps

1. **Deploy migrations** - Apply the database migrations to create the trace summaries materialized view and indexes
2. **UI Integration** - Update the UI to use SRQL queries for trace browsing and correlation
3. **Performance Validation** - Monitor query performance and adjust indexes as needed
4. **Dashboard Creation** - Build observability dashboards using the new correlation capabilities

This implementation provides a unified query interface for logs, traces, and metrics, enabling powerful observability workflows through first-class correlation support in SRQL.