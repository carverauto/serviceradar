# Design: Trace Summaries Materialized View

## Problem Analysis

### Current Architecture

The `otel_trace_summaries` SRQL entity generates trace-level aggregations at query time:

```
┌─────────────────────────────────────────────────────────────────┐
│ User Request: in:otel_trace_summaries time:last_24h             │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│ SRQL (trace_summaries.rs)                                       │
│ ┌─────────────────────────────────────────────────────────────┐ │
│ │ WITH trace_summaries AS (                                   │ │
│ │     SELECT trace_id, max(...), array_agg(...), count(*)     │ │
│ │     FROM otel_traces                                        │ │
│ │     WHERE timestamp >= $1 AND timestamp <= $2               │ │
│ │     GROUP BY trace_id   ← EXPENSIVE                         │ │
│ │ )                                                           │ │
│ │ SELECT * FROM trace_summaries LIMIT 100                     │ │
│ └─────────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│ CNPG/TimescaleDB                                                │
│ ┌─────────────────────────────────────────────────────────────┐ │
│ │ otel_traces hypertable                                      │ │
│ │ - Millions of span rows                                     │ │
│ │ - Full scan + GROUP BY for every query                      │ │
│ └─────────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────────┘
```

**Performance characteristics:**
- Query time scales linearly with span count in time range
- 100k spans → ~1s, 1M spans → ~10s
- Each dashboard load repeats this expensive aggregation

### Proposed Architecture

Pre-compute trace summaries in a materialized view, refreshed periodically:

```
┌─────────────────────────────────────────────────────────────────┐
│ pg_cron (every 2 min)                                           │
│ REFRESH MATERIALIZED VIEW CONCURRENTLY otel_trace_summaries     │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│ CNPG/TimescaleDB                                                │
│ ┌─────────────────────────────────────────────────────────────┐ │
│ │ otel_trace_summaries (MATERIALIZED VIEW)                    │ │
│ │ - Pre-aggregated: one row per trace                         │ │
│ │ - Indexed: timestamp DESC, root_service_name                │ │
│ │ - Rolling 7-day window                                      │ │
│ └─────────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────────┘
                              ▲
                              │
┌─────────────────────────────────────────────────────────────────┐
│ SRQL (trace_summaries.rs)                                       │
│ ┌─────────────────────────────────────────────────────────────┐ │
│ │ SELECT * FROM otel_trace_summaries                          │ │
│ │ WHERE timestamp >= $1 AND timestamp <= $2                   │ │
│ │ ORDER BY timestamp DESC LIMIT 100                           │ │
│ │                                                             │ │
│ │ ← Simple indexed lookup, no aggregation                     │ │
│ └─────────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────────┘
```

## Design Decisions

### 1. Materialized View vs CAGG

| Criteria | CAGG | MV | Decision |
|----------|------|-----|----------|
| Grouping | time_bucket only | Any (trace_id) | **MV** - traces group by ID |
| Aggregations | Combinable only | Any SQL | **MV** - need array_agg |
| Refresh | Automatic, incremental | Manual, full | MV acceptable with pg_cron |
| TimescaleDB required | Yes | No | MV more portable |

**Decision**: Use a standard PostgreSQL Materialized View because trace summaries fundamentally group by `trace_id`, not time bucket.

### 2. Refresh Strategy

**Options considered:**
1. **Trigger-based**: Refresh on INSERT to otel_traces
   - Rejected: Too frequent, would cause contention
2. **Application-driven**: Web-ng triggers refresh before query
   - Rejected: Adds latency to first request, complex coordination
3. **pg_cron scheduled**: Refresh every N minutes
   - **Selected**: Simple, predictable, decoupled from queries

**Refresh interval**: 2 minutes (configurable)
- Fast enough for operational dashboards
- Slow enough to avoid refresh contention
- Uses `CONCURRENTLY` to allow reads during refresh

### 3. Rolling Window

**Why 7 days:**
- Matches typical observability retention expectations
- Bounds MV storage (~10-50MB depending on trace volume)
- Old traces can still use CTE fallback if needed
- Configurable via migration variable if needed

### 4. Index Strategy

```sql
-- Required for CONCURRENTLY refresh
CREATE UNIQUE INDEX ON otel_trace_summaries (trace_id);

-- Primary query pattern: time-ordered listing
CREATE INDEX ON otel_trace_summaries (timestamp DESC);

-- Common filter: by service
CREATE INDEX ON otel_trace_summaries (root_service_name, timestamp DESC);
```

### 5. SRQL Query Path Selection

```
┌─────────────────────────────────────────────────┐
│ Query: in:otel_trace_summaries time:last_24h    │
└─────────────────────────────────────────────────┘
                      │
                      ▼
              ┌───────────────┐
              │ MV exists and │
              │ covers range? │
              └───────────────┘
                /           \
              YES            NO
              /               \
             ▼                 ▼
    ┌─────────────┐    ┌─────────────┐
    │ Query MV    │    │ Use CTE     │
    │ directly    │    │ fallback    │
    └─────────────┘    └─────────────┘
```

**MV detection**: Check if `otel_trace_summaries` relation exists at startup or first query. Cache result.

## Schema Definition

```sql
CREATE MATERIALIZED VIEW otel_trace_summaries AS
SELECT
    trace_id,
    max(timestamp) AS timestamp,
    max(span_id) FILTER (WHERE coalesce(parent_span_id, '') = '') AS root_span_id,
    max(name) FILTER (WHERE coalesce(parent_span_id, '') = '') AS root_span_name,
    max(service_name) FILTER (WHERE coalesce(parent_span_id, '') = '') AS root_service_name,
    max(kind) FILTER (WHERE coalesce(parent_span_id, '') = '') AS root_span_kind,
    min(start_time_unix_nano) AS start_time_unix_nano,
    max(end_time_unix_nano) AS end_time_unix_nano,
    greatest(0, coalesce(
        (max(end_time_unix_nano) - min(start_time_unix_nano))::double precision / 1000000.0,
        0
    )) AS duration_ms,
    max(status_code) FILTER (WHERE coalesce(parent_span_id, '') = '') AS status_code,
    max(status_message) FILTER (WHERE coalesce(parent_span_id, '') = '') AS status_message,
    array_agg(DISTINCT service_name) FILTER (WHERE service_name IS NOT NULL) AS service_set,
    count(*) AS span_count,
    sum(CASE WHEN coalesce(status_code, 0) != 1 THEN 1 ELSE 0 END) AS error_count
FROM otel_traces
WHERE timestamp > NOW() - INTERVAL '7 days'
  AND trace_id IS NOT NULL
GROUP BY trace_id;

-- Required for REFRESH CONCURRENTLY
CREATE UNIQUE INDEX idx_trace_summaries_trace_id
    ON otel_trace_summaries (trace_id);

-- Query optimization
CREATE INDEX idx_trace_summaries_timestamp
    ON otel_trace_summaries (timestamp DESC);

CREATE INDEX idx_trace_summaries_service_timestamp
    ON otel_trace_summaries (root_service_name, timestamp DESC);
```

## Tradeoffs

| Aspect | Benefit | Cost |
|--------|---------|------|
| Query speed | 10-100x faster | Up to 2 min stale data |
| Storage | N/A | ~10-50MB for MV |
| Complexity | Simpler SRQL queries | Additional migration + cron job |
| Portability | Works without TimescaleDB | Requires pg_cron or external scheduler |

## Alternatives Considered

1. **Incremental MV refresh**: PostgreSQL doesn't support incremental refresh for MVs with GROUP BY on non-time columns. Would require custom trigger-based solution - too complex.

2. **Application-level caching**: Cache trace summaries in Redis/memory. Rejected: adds infrastructure dependency, cache invalidation complexity.

3. **Denormalized trace table**: Write trace summaries on span ingestion. Rejected: requires changes to ingest pipeline, complex partial-trace handling.

4. **Query optimization only**: Add indexes to otel_traces for the CTE. Tested: helps marginally but GROUP BY remains expensive.

## Future Enhancements

1. **Configurable retention**: Allow per-deployment MV window via migration variable
2. **Partition MV by time**: If MV grows large, partition by week/month
3. **Real-time layer**: Combine MV (historical) with live CTE (last 5 min) for fresher data
