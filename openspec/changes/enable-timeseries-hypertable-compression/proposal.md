# Change: Enable TimescaleDB compression on the two largest hypertables

GitHub: [carverauto/serviceradar#478](https://github.com/carverauto/serviceradar/issues/478)

## Why

Neither of the two hypertables that make up most of a ServiceRadar database
has compression enabled. Measured on `demo`:

| Hypertable | Size | `compression_enabled` | Compressed chunks |
|---|---|---|---|
| `platform.ocsf_network_activity` | 82 GB | `false` | 0 / 91 |
| `platform.timeseries_metrics` | 51 GB | `false` | 0 / 8 |

Both are append-only time-series with a retention policy already attached
(90 days and 7 days). TimescaleDB compression is designed for that shape and
typically returns 5–10× on this kind of data.

Hosted tenants run CloudNativePG with 3 replicas, so every logical GB is
billed as 3 GB of block storage at $0.10/GB-mo — $0.30/GB-mo effective.
133 GB across these two tables is therefore ~$40/mo of block storage per
demo-sized deployment, and it is the same data driving write IOPS and
page-cache pressure on the primary.

This is independent of the analytics-store / Parquet work in
`add-analytics-store-drivers` (GH #477) and ships first. It shrinks the
problem before that cutover, and it keeps paying off for whatever stays in
Postgres afterwards.

## What Changes

- Document why compression is off today (it was never installed — not a
  deliberate disable) and confirm the ingest path does not mutate closed
  chunks.
- Enable TimescaleDB compression on `ocsf_network_activity` and
  `timeseries_metrics` with an explicit per-table `compress_after` /
  `segmentby` / `orderby` policy.
- Apply the policy from a migration *and* from
  `DataRetentionWorker`, matching how retention is already reconciled, so a
  fresh provision gets it rather than only long-lived deployments.
- Verify compression ratio and query-latency effect on `demo` before any
  tenant rollout.

## Impact

- Affected specs: `observability-signals`
- Affected code:
  - new migration under `elixir/serviceradar_core/priv/repo/migrations/`
  - `ServiceRadar.Observability.DataRetentionWorker`
  - tests covering the helper SQL and the worker reconcile path
- No Helm values, no SRQL change, no ingest-path change.
- Does not modify any requirement heading touched by
  `add-tiered-telemetry-offload` or `add-analytics-store-drivers`.

## Out of scope

- Other hypertables (`cpu_metrics`, `logs`, `otel_*`, `ocsf_events`, MTR,
  BMP). Same pattern, later change, after `demo` numbers exist.
- Changing retention windows.
- The Parquet / DuckDB analytics-store work (GH #477).
