# Tasks

## 1. Schema / Migrations (CNPG)
- [ ] Confirm the next migration number under `pkg/db/cnpg/migrations/` (currently only `00000000000001_schema.up.sql` exists, so the next is expected to be `00000000000002`).
- [ ] Add an idempotent CNPG migration `pkg/db/cnpg/migrations/<NN>_observability_rollups.up.sql` that:
  - [ ] Creates a 5-minute CAGG for `otel_metrics` KPIs (total/errors/slow/avg/p95).
  - [ ] Creates a 5-minute CAGG for trace-like KPIs based on `otel_traces` root spans (total/errors/avg/p95).
  - [ ] Creates a 5-minute CAGG for `logs` severity counts.
  - [ ] Adds continuous aggregate refresh policies for each CAGG.
  - [ ] (Optional) Adds retention policies for the CAGGs (match base retention window when enabled).
- [ ] Add a down migration if the project requires down migrations for CNPG (otherwise document no-op behavior).

## 2. Documentation
- [ ] Add an operator runbook describing:
  - [ ] How to verify rollups exist (`\d+` / `pg_matviews`)
  - [ ] How to verify refresh policies (`timescaledb_information.jobs`)
  - [ ] How to inspect failures (`timescaledb_information.job_errors`)
  - [ ] Manual refresh commands for backfills (`CALL refresh_continuous_aggregate(...)`)

## 3. Verification
- [ ] Validate that rollup totals match raw-table totals for a fixed time window (ex: last 1h / last 24h), within expected ingestion lateness.
- [ ] Validate dashboard latency improvements by comparing:
  - [ ] Raw SRQL stats queries
  - [ ] Rollup-backed queries (sum buckets in window)

## 4. Follow-ups (Not part of this change)
- [ ] Update `web-ng` Observability + Analytics KPI cards to query rollups when available, with a safe fallback to raw hypertables.
- [ ] If needed, evaluate `timescaledb_toolkit` for cheaper p95 percentiles at scale.
