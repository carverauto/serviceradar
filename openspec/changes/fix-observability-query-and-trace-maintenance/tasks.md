## 1. CNPG and Query Path
- [ ] 1.1 Add a CNPG migration that provides an index-backed execution path for `COALESCE(observed_timestamp, timestamp)` on `platform.logs`.
- [ ] 1.2 Add a CNPG migration that creates `platform.traces_stats_5m` with the refresh policy expected by the traces summary cards.
- [ ] 1.3 Validate the default logs SRQL query with `EXPLAIN ANALYZE` against demo-scale data and record the expected indexed plan.

## 2. Trace Summary Maintenance
- [ ] 2.1 Update `RefreshTraceSummariesWorker` scheduling/uniqueness so orphaned `executing` rows cannot permanently block future runs.
- [ ] 2.2 Add explicit stale periodic-job cleanup/reaping so abandoned Oban rows are transitioned out of `executing` and cannot accumulate silently.
- [ ] 2.3 Ensure trace summary maintenance prunes `platform.otel_trace_summaries` to the supported retention window and remains safe to rerun after restart/failover.
- [ ] 2.4 Add automated tests for trace summary scheduling recovery, orphaned job cleanup, and summary cleanup behavior.

## 3. Verification and Operations
- [ ] 3.1 Add verification for missing trace rollups or stale trace summary freshness before the UI silently serves stale data.
- [ ] 3.2 Document the demo remediation flow for clearing orphaned trace refresh jobs and rebuilding current trace summary state.
- [ ] 3.3 Re-validate `/observability` logs and traces behavior in demo after the changes are applied.

## 4. Alert Retention
- [ ] 4.1 Add automatic maintenance that prunes `platform.alerts` rows older than the supported retention window.
- [ ] 4.2 Wire the alert retention cleanup into periodic scheduling with operator-visible job metadata and runtime overrides.
- [ ] 4.3 Add automated coverage for alert retention worker configuration and batched delete behavior.
