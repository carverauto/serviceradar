# Change: Optimize Trace Summaries with Materialized View

## Why

The traces tab in the observability dashboard loads significantly slower than the logs tab. Root cause analysis shows:

1. **On-the-fly aggregation**: The `otel_trace_summaries` entity in SRQL generates a CTE that scans and aggregates the entire `otel_traces` table for every query
2. **Expensive GROUP BY trace_id**: Each query must group all spans by trace_id to compute root span info, duration, span count, error count, and service set
3. **No pre-computation**: Unlike logs (which query raw rows) or stats (which use CAGGs), trace summaries have no materialized backing

**Current query pattern** (from `rust/srql/src/query/trace_summaries.rs`):
```sql
WITH trace_summaries AS (
    SELECT
        trace_id,
        max(timestamp) AS timestamp,
        max(span_id) FILTER (WHERE parent_span_id = '') AS root_span_id,
        max(name) FILTER (WHERE parent_span_id = '') AS root_span_name,
        max(service_name) FILTER (WHERE parent_span_id = '') AS root_service_name,
        array_agg(DISTINCT service_name) AS service_set,
        count(*) AS span_count,
        sum(CASE WHEN status_code != 1 THEN 1 ELSE 0 END) AS error_count,
        ...
    FROM otel_traces
    WHERE timestamp >= $1 AND timestamp <= $2
    GROUP BY trace_id
)
SELECT ... FROM trace_summaries LIMIT 100
```

**Why a Materialized View (not a CAGG)**:
- CAGGs require `time_bucket()` grouping - trace summaries group by `trace_id`
- CAGGs need "combinable" aggregations - `array_agg(DISTINCT ...)` isn't mergeable
- Traces span time buckets - a trace's spans may arrive over minutes
- MVs support any SQL and can be refreshed incrementally with `CONCURRENTLY`

## What Changes

### 1. Database: Create `otel_trace_summaries` Materialized View

Add a materialized view that pre-computes trace aggregations:
- Refreshed every 1-5 minutes via pg_cron or application scheduler
- Rolling 7-day window to bound storage
- Indexed on `timestamp DESC` and `root_service_name` for common query patterns
- Uses `REFRESH MATERIALIZED VIEW CONCURRENTLY` to avoid blocking reads

### 2. SRQL: Update trace_summaries query to use MV

Modify `rust/srql/src/query/trace_summaries.rs` to:
- Query the `otel_trace_summaries` MV directly instead of generating a CTE
- Fall back to CTE for time ranges outside the MV window (optional)
- Simplify query construction since aggregation is pre-computed

### 3. Database: Add pg_cron refresh job

Create a scheduled job to refresh the MV:
- Default: every 2 minutes
- Uses `CONCURRENTLY` to allow reads during refresh
- Configurable via environment or KV

## Impact

- **Affected components**: CNPG (new MV + indexes + refresh job), SRQL (query simplification)
- **Performance improvement**: 10-100x faster trace list queries depending on data volume
- **Storage cost**: ~10-50MB for 7 days of trace summaries (depends on trace volume)
- **Freshness tradeoff**: Trace summaries may be up to 2 minutes stale (acceptable for dashboard use)
- **Risk**: Low. Additive change - can fall back to CTE if MV is unavailable

## Success Criteria

1. Traces tab loads in <500ms (currently 3-10s with high trace volume)
2. MV refresh completes in <10s and doesn't block reads
3. SRQL trace_summaries queries return same data structure as before
4. No changes required to web-ng (SRQL response format unchanged)
