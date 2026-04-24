## Context
The current demo environment shows three independent observability failures:

1. Logs list queries are slow even though the page shell is fast.
   - `GET /observability` returns in about 16 ms.
   - The live `web-ng` release takes about 5.3 s to execute `in:logs time:last_7d sort:timestamp:desc`.
   - The translated SQL orders by `COALESCE(observed_timestamp, timestamp) DESC`.
   - `EXPLAIN ANALYZE` shows a parallel sequential scan and top-N sort across roughly 5.7 million log rows in the 7-day window.

2. Trace maintenance is stale and partially broken.
   - `platform.otel_trace_summaries` is about 14 GB with about 25 million rows.
   - The summary table only contains data from 2026-02-14 through 2026-02-21.
   - Two `ServiceRadar.Jobs.RefreshTraceSummariesWorker` rows remain stuck in `executing` since 2026-02-11.
   - The worker's uniqueness includes `:executing`, so those orphaned rows block new scheduled jobs.
   - The traces UI asks SRQL for `traces_stats_5m`, but that CAGG is absent in demo.

3. Metrics duration rollups are not actually maintained.
   - `platform.otel_metrics_hourly_stats` exists as a plain hypertable with 0 rows.
   - `timescaledb_information.continuous_aggregates` has no `otel_metrics_hourly_stats` entry.
   - Raw `platform.otel_metrics` has live data, but analytics and observability widgets that trust the hourly rollup render `0 traces`, `0ms`, and `0.0%`.

Retention on the raw Timescale hypertables is still configured and running, so this proposal focuses on the specific regressions in the query path and in the maintained observability rollups.

## Goals / Non-Goals
- Goals:
  - Keep the observed-timestamp semantics from `update-log-time-ordering` while restoring fast first-page log queries at demo-scale volumes.
  - Ensure trace summaries stay fresh and self-pruning after node restarts, CNPG failovers, and aborted worker runs.
  - Make the traces summary cards depend on a real `traces_stats_5m` backend in `platform`.
  - Replace the fake `otel_metrics_hourly_stats` storage with a real continuously refreshed metrics rollup so duration/error widgets have a canonical backend.
  - Give operators an explicit freshness signal and remediation path for stale trace summary state.
- Non-Goals:
  - Redesign the observability UI or change tab defaults.
  - Rewrite raw log or trace timestamps already stored in CNPG.
  - Backfill unlimited historical trace summaries beyond the intended retention window.

## Decisions
- Decision: Preserve effective log timestamp semantics.
  The logs UI and SRQL will continue to filter and order on `COALESCE(observed_timestamp, timestamp)`. The fix is to provide a matching index-backed storage/query path rather than reverting to plain event timestamps.

- Decision: Treat `otel_trace_summaries` as the source of truth for trace list views.
  The proposal aligns the spec with the current maintained table implementation and requires explicit pruning of rows older than the intended summary window.

- Decision: Make trace summary scheduling bounded and recoverable.
  Recurring trace summary maintenance must not rely on indefinite uniqueness across `:executing` jobs. The scheduling model must allow recovery from orphaned jobs after restart or failover while still preventing duplicate steady-state execution.

- Decision: Periodic Oban jobs need explicit orphan reaping.
  A stuck `executing` row is not an acceptable steady state. The system must detect stale periodic jobs, transition or remove them safely, and emit enough signal for operators to verify that recovery happened.

- Decision: Make the traces UI rollup backend explicit.
  The `traces_stats_5m` CAGG and refresh policy become required CNPG assets rather than an implicit expectation in SRQL and LiveView code.

- Decision: Replace dead metrics rollup storage instead of layering more fallbacks.
  `platform.otel_metrics_hourly_stats` should become a real continuous aggregate with refresh, retention, and bounded backfill. Dashboard code should keep using the maintained rollup instead of adding raw-table fallback queries that hide schema drift.

## Risks / Trade-offs
- An expression index on the effective log timestamp increases write amplification on the `logs` hypertable.
  Mitigation: scope the index to the exact expression used by SRQL and validate the benefit with `EXPLAIN ANALYZE` against demo-scale data.

- Recoverable job uniqueness can allow overlapping enqueues if the bounds are too loose.
  Mitigation: pair bounded uniqueness with idempotent incremental upserts and explicit stale-job recovery logic.

- Automatic orphan reaping can interfere with legitimately long-running jobs if the stale threshold is set incorrectly.
  Mitigation: scope the cleanup behavior to periodic jobs with known runtime bounds and require the stale threshold to exceed the normal execution envelope.

- Creating `traces_stats_5m` adds another refresh workload to CNPG.
  Mitigation: use a 5-minute cadence with bounded offsets and keep aggregation restricted to root spans.

- Replacing `otel_metrics_hourly_stats` in place can conflict with already broken installs that still have the old table.
  Mitigation: make the migration explicitly detect whether the existing relation is already a continuous aggregate, drop only the dead table form, then create the replacement CAGG idempotently before adding refresh/retention policy.

## Migration Plan
1. Add CNPG migrations for the effective log timestamp index, the `traces_stats_5m` CAGG, and the replacement `otel_metrics_hourly_stats` CAGG with refresh/retention policy.
2. Update trace summary scheduling to recover from orphaned jobs, reap stale periodic job state, and keep the summary table pruned to the supported window.
3. Add instrumentation or verification that reports stale trace summary freshness and missing rollup assets.
4. In demo, clear orphaned trace summary worker state, run the repaired maintenance flow, and verify log query plans, trace freshness, and non-zero maintained metrics rollup output.

## Open Questions
- Should stale trace summary recovery happen automatically at worker startup, or via a separate maintenance/reconciliation job?
- Do we want a dedicated admin/operator surface for trace summary freshness, or is telemetry/logging sufficient for the first pass?
