# Change: Add TimescaleDB rollups for Observability KPIs

## Why
- The `web-ng` Observability/Analytics KPI cards currently rely on real-time aggregate queries over high-volume hypertables (`logs`, `otel_metrics`, `otel_traces`).
- These queries are slow at scale and appear to be inconsistent with the legacy UI (ex: traces/metrics totals and error-rate calculations).
- TimescaleDB continuous aggregates provide fast, predictable KPI queries by precomputing time-bucketed summaries on a schedule.

## What Changes
- Add CNPG migrations that create TimescaleDB continuous aggregates (CAGGs) for:
  - `otel_metrics` KPI rollups (total, errors, slow, avg/p95 duration)
  - `otel_traces` KPI rollups (trace-like counts based on root spans, errors, avg/p95 duration)
  - `logs` severity rollups (counts by level)
- Add refresh policies for each CAGG so dashboards can query rollups rather than raw hypertables.
- Document validation queries and operational guidance (refresh, job health, failure recovery).

## Non-Goals
- No UI cut-over is required in this change: `web-ng` MAY continue querying raw hypertables until we explicitly switch it.
- No changes to telemetry ingestion or data retention policies.
- No migration of the legacy React/Next.js web stack.

## Impact
- Affected capability: `cnpg` (new database objects + policies).
- Affected code paths (future follow-up): `web-ng` SRQL dashboards and KPI cards can be updated to query rollups for speed/correctness.
- Operational considerations: continuous aggregate policies must be monitored (job errors) and may require recreation if Timescale function OIDs change (see prior change `fix-cnpg-continuous-aggregate-cache-error`).

