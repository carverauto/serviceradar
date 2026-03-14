# Change: Restore observability query performance and maintained observability rollups

## Why
The demo observability and analytics surfaces regressed after the effective log timestamp change and the CNPG 18 upgrade window. In the running `web-ng` release, the exact logs SRQL query `in:logs time:last_7d sort:timestamp:desc` takes about 5.3 seconds because it orders by `COALESCE(observed_timestamp, timestamp)` without a matching index, forcing a full scan and sort across millions of recent log rows. At the same time, trace summary maintenance is stale: `otel_trace_summaries` contains only data from February 14, 2026 through February 21, 2026, the `RefreshTraceSummariesWorker` has orphaned `executing` jobs stuck since February 11, 2026, and the `traces_stats_5m` rollup queried by the traces UI does not exist in demo. Separately, the analytics duration cards depend on `platform.otel_metrics_hourly_stats`, which exists as an empty hypertable rather than a real continuously maintained rollup.

## What Changes
- Add CNPG support for index-backed log queries that filter and sort on the effective log timestamp `COALESCE(observed_timestamp, timestamp)` without changing the user-visible semantics introduced by `update-log-time-ordering`.
- Align the trace summary storage spec with the current incremental summary table implementation rather than the old materialized view model.
- Make trace summary scheduling recoverable after restarts, failovers, and orphaned `executing` jobs so stale uniqueness state cannot permanently block future maintenance runs.
- Require explicit detection and cleanup/reaping of orphaned periodic Oban jobs so abandoned rows do not remain indefinitely in `executing` state.
- Require the `traces_stats_5m` continuous aggregate and refresh policy used by the traces summary cards.
- Replace the dead `platform.otel_metrics_hourly_stats` table with a real continuous aggregate, refresh policy, retention policy, and bounded backfill so analytics and observability duration cards read from a maintained source of truth.
- Require automatic alert retention cleanup so `platform.alerts` does not grow without bound in degraded environments.
- Add operational verification so demo-like environments can detect stale trace summary freshness before the UI silently degrades.

## Impact
- Affected specs: `cnpg`, `job-scheduling`
- Affected code: `rust/srql` logs planner, Elixir trace summary and alert retention workers, analytics/observability dashboard consumers, cron uniqueness, CNPG migrations for logs/traces/metrics indexes and CAGGs, demo remediation/runbooks
