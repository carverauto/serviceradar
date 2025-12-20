# Tasks: Optimize Trace Summaries with Materialized View

## Phase 1: Database Schema

- [x] **1.1** Create migration file `pkg/db/cnpg/migrations/00000000000007_trace_summaries_mv.up.sql`
  - [x] Create `otel_trace_summaries` materialized view with 7-day rolling window
  - [x] Add unique index on `trace_id` for CONCURRENTLY refresh
  - [x] Add index on `(timestamp DESC)` for time-range queries
  - [x] Add index on `(root_service_name, timestamp DESC)` for service filtering
  - [x] Grant SELECT to `spire` role
- [x] **1.2** Create down migration `00000000000007_trace_summaries_mv.down.sql`
- [x] **1.3** Add pg_cron job for periodic refresh (every 2 minutes)
  - [x] Use `REFRESH MATERIALIZED VIEW CONCURRENTLY`
  - [x] Add job only if pg_cron extension is available
- [x] **1.4** Test migration locally: apply, verify MV exists, verify refresh works

## Phase 2: SRQL Query Updates

- [x] **2.1** Update `rust/srql/src/query/trace_summaries.rs` to query MV directly
  - Note: Removed CTE approach entirely; MV is always used
- [x] **2.2** Implement MV-based query builder
  - [x] Replace CTE with direct SELECT from `otel_trace_summaries`
  - [x] Apply time range filters on `timestamp` column
  - [x] Apply existing filter logic (trace_id, root_service_name, etc.)
  - [x] Preserve ORDER BY and LIMIT/OFFSET
- [x] **2.3** Fix bind ordering bug in stats mode (placeholders must match bind order)
- [x] **2.4** Run SRQL tests: `cargo test` in `rust/srql` - 51 tests pass

## Phase 3: Build and Deploy

- [x] **3.1** Build new images with `make push_all`
- [x] **3.2** Deploy to local docker-compose and verify:
  - [x] Migration runs successfully
  - [x] MV is created and populated (23,343 trace summaries)
  - [x] pg_cron job scheduled (where available)
  - [x] Traces tab loads quickly
- [x] **3.3** Measure performance improvement
  - Old CTE approach: 24.4ms
  - New MV approach: 0.6ms
  - **40x improvement**

## Phase 4: Cleanup

- [x] **4.1** Mark change complete after verification

## Verification Results

```bash
# MV exists and has data
SELECT count(*) FROM otel_trace_summaries;
# Result: 23343

# Query performance comparison
EXPLAIN ANALYZE SELECT * FROM otel_trace_summaries WHERE timestamp >= NOW() - INTERVAL '24 hours' LIMIT 50;
# Result: 0.6ms (Index Scan)

# Old CTE approach for comparison
EXPLAIN ANALYZE WITH trace_summaries AS (...) SELECT * FROM trace_summaries LIMIT 50;
# Result: 24.4ms (Parallel Seq Scan + HashAggregate)
```
