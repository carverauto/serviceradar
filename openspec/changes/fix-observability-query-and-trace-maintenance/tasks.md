## 1. CNPG and Query Path
- [x] 1.1 Add a CNPG migration that provides an index-backed execution path for `COALESCE(observed_timestamp, timestamp)` on `platform.logs`.
- [x] 1.2 Add a CNPG migration that creates `platform.traces_stats_5m` with the refresh policy expected by the traces summary cards.
- [x] 1.3 Validate the default logs SRQL query with `EXPLAIN ANALYZE` against demo-scale data and record the expected indexed plan.

## 2. Trace Summary Maintenance
- [x] 2.1 Update `RefreshTraceSummariesWorker` scheduling/uniqueness so orphaned `executing` rows cannot permanently block future runs.
- [x] 2.2 Add explicit stale periodic-job cleanup/reaping so abandoned Oban rows are transitioned out of `executing` and cannot accumulate silently.
- [x] 2.3 Ensure trace summary maintenance prunes `platform.otel_trace_summaries` to the supported retention window and remains safe to rerun after restart/failover.
- [x] 2.4 Add automated tests for trace summary scheduling recovery, orphaned job cleanup, and summary cleanup behavior.

## 3. Verification and Operations
- [ ] 3.1 Add verification for missing trace rollups or stale trace summary freshness before the UI silently serves stale data.
- [ ] 3.2 Document the demo remediation flow for clearing orphaned trace refresh jobs and rebuilding current trace summary state.
- [ ] 3.3 Re-validate `/observability` logs and traces behavior in demo after the changes are applied.

## 4. Alert Retention
- [x] 4.1 Add automatic maintenance that prunes `platform.alerts` rows older than the supported retention window.
- [x] 4.2 Wire the alert retention cleanup into periodic scheduling with operator-visible job metadata and runtime overrides.
- [x] 4.3 Add automated coverage for alert retention worker configuration and batched delete behavior.

## 5. Metrics Rollup Replacement
- [x] 5.1 Replace the dead `platform.otel_metrics_hourly_stats` hypertable with a real continuous aggregate in `platform`.
- [x] 5.2 Add refresh policy, retention policy, and bounded backfill for the replacement metrics rollup.
- [x] 5.3 Keep dashboard duration/error widgets wired to the maintained metrics rollup instead of adding raw-table fallback queries.

## 6. Dashboard Card Correctness
- [x] 6.1 Update observability events summary cards to use aggregate-backed counts instead of the current paginated row slice.
- [x] 6.2 Fix analytics event/log previews so they render real severity, message, and host details from live demo payloads.
- [x] 6.3 Fix analytics critical-log previews so `CRITICAL`/`ALERT`/`EMERGENCY` rows are treated as actionable critical logs instead of rendering an empty-state card.
