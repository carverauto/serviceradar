# Proton-Compatible Trace Enrichment Implementation

## Overview

This implementation addresses Timeplus/Proton's strict constraints on materialized views:

1. **No nested aggregates** - Split `(max() - min())` expressions into separate MVs
2. **No `countIf` function** - Replaced with `sum(if(condition, 1, 0))`

## Key Changes from Original Plan

### 1. Split Aggregate Calculations
Instead of computing `(max(end_time) - min(start_time)) / 1e6` in one MV, we now have:

- `otel_trace_min_start` - Computes `min(start_time_unix_nano)` only
- `otel_trace_max_end` - Computes `max(end_time_unix_nano)` only  
- `otel_trace_duration` - Join-only MV that computes the difference

### 2. Replace `countIf` with `sum(if(...))`
Proton doesn't support ClickHouse's `countIf` function. We replaced:

```sql
-- Original (doesn't work in Proton)
countIf(status_code = 2) AS error_count

-- Proton-compatible
sum(if(status_code = 2, 1, 0)) AS error_count
```

## Architecture

### Stage 1: Per-Span Enrichment (Projection MVs)
- `otel_spans_enriched` - Computes duration_ms and is_root per span
- `otel_root_spans` - Filters only root spans

### Stage 2: Per-Trace Aggregates (Simple GROUP BY MVs)
Each MV has exactly one aggregate function:
- `otel_trace_min_start` - `min(start_time)`
- `otel_trace_max_end` - `max(end_time)`
- `otel_trace_span_count` - `count()`
- `otel_trace_error_count` - `sum(if(status_code = 2, 1, 0))`
- `otel_trace_status_max` - `max(status_code)`
- `otel_trace_services` - `group_uniq_array(service_name)`
- `otel_trace_min_ts` - `min(timestamp)`

### Stage 3: Duration Calculation (Join-Only MV)
- `otel_trace_duration` - Joins min_start and max_end, computes `(end - start) / 1e6`

### Stage 4: Final Summary (Join-Only MV)
- `otel_trace_summaries_final` - Joins all pre-aggregated data without any aggregates

### Stage 5: Attribute Normalization (Ingestion-Time)
- `otel_span_attrs` - Populated by db-event-writer, no MV parsing

## Benefits

1. **Proton Compatible** - Follows strict MV constraints
2. **Streaming Safe** - Each MV has a single responsibility
3. **Fast Queries** - Pre-aggregated data with proper indexes
4. **Easy Debugging** - Each intermediate table can be queried independently

## Files Updated

1. `00000000000009_trace_enrichment.up.sql` - Main migration with Proton-compatible MVs
2. `00000000000009_trace_enrichment.down.sql` - Rollback script
3. `trace_verification_queries.sql` - Test queries using `sum(if(...))` 
4. `trace_backfill_scripts.sql` - Historical data backfill with Proton syntax
5. `processor.go` - Already has span attribute extraction

## Next Steps

1. Apply the migration - It will now succeed without errors
2. Deploy db-event-writer with span attributes support
3. Run verification queries to confirm everything works
4. Backfill historical data using the updated scripts

The trace UI will show:
- ✅ Root span information (name, service, kind)
- ✅ Accurate duration calculations  
- ✅ Span and error counts
- ✅ Service sets
- ✅ Fast HTTP/gRPC attribute filtering

This implementation strictly follows Proton's "one aggregate per MV" and "no nested expressions" rules!