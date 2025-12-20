# Tasks: Optimize Trace Summaries with Materialized View

## Phase 1: Database Schema

- [ ] **1.1** Create migration file `pkg/db/cnpg/migrations/00000000000007_trace_summaries_mv.up.sql`
  - [ ] Create `otel_trace_summaries` materialized view with 7-day rolling window
  - [ ] Add unique index on `trace_id` for CONCURRENTLY refresh
  - [ ] Add index on `(timestamp DESC)` for time-range queries
  - [ ] Add index on `(root_service_name, timestamp DESC)` for service filtering
  - [ ] Grant SELECT to `spire` role
- [ ] **1.2** Create down migration `00000000000007_trace_summaries_mv.down.sql`
- [ ] **1.3** Add pg_cron job for periodic refresh (every 2 minutes)
  - [ ] Use `REFRESH MATERIALIZED VIEW CONCURRENTLY`
  - [ ] Add job only if pg_cron extension is available
- [ ] **1.4** Test migration locally: apply, verify MV exists, verify refresh works

## Phase 2: SRQL Query Updates

- [ ] **2.1** Update `rust/srql/src/query/trace_summaries.rs` to detect MV availability
  - [ ] Add config flag or runtime check for MV presence
  - [ ] Default to MV path when available
- [ ] **2.2** Implement MV-based query builder
  - [ ] Replace CTE with direct SELECT from `otel_trace_summaries`
  - [ ] Apply time range filters on `timestamp` column
  - [ ] Apply existing filter logic (trace_id, root_service_name, etc.)
  - [ ] Preserve ORDER BY and LIMIT/OFFSET
- [ ] **2.3** Keep CTE fallback for edge cases
  - [ ] Time ranges outside MV window (>7 days ago)
  - [ ] When MV doesn't exist (fresh install before migration)
- [ ] **2.4** Run SRQL tests: `cargo test` in `rust/srql`
- [ ] **2.5** Add integration test for MV query path

## Phase 3: Build and Deploy

- [ ] **3.1** Build new CNPG image with migration: `make push_all` or bazel targets
- [ ] **3.2** Build new SRQL image with query changes
- [ ] **3.3** Deploy to local docker-compose and verify:
  - [ ] Migration runs successfully
  - [ ] MV is created and populated
  - [ ] pg_cron job is scheduled
  - [ ] Traces tab loads quickly
- [ ] **3.4** Measure performance improvement (before/after timing)

## Phase 4: Documentation and Cleanup

- [ ] **4.1** Update `fix-observability-logs-stats-cards` tasks if any overlap
- [ ] **4.2** Add MV to architecture docs if maintaining a database schema reference
- [ ] **4.3** Mark change complete after production verification

## Dependencies

- Phase 2 can start in parallel with Phase 1 (schema design is known)
- Phase 3 requires both Phase 1 and Phase 2 complete
- No web-ng changes required (SRQL response format unchanged)

## Verification

After deployment, verify:
```bash
# Check MV exists and has data
docker exec <cnpg> psql -U serviceradar -d serviceradar -c "SELECT count(*) FROM otel_trace_summaries;"

# Check pg_cron job
docker exec <cnpg> psql -U serviceradar -d serviceradar -c "SELECT * FROM cron.job WHERE command LIKE '%trace_summaries%';"

# Time a trace query
time curl -s 'http://localhost/api/query' -H 'Authorization: Bearer ...' \
  -d '{"query": "in:otel_trace_summaries time:last_24h"}' | jq '.results | length'
```
