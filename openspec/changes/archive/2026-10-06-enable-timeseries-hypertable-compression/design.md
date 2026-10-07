## Context

TimescaleDB compression is already used in this repo for smaller hypertables
(`capacity_forecasts`, `endpoint_inventory_scan_history`,
`endpoint_package_events`, the inventory count rollups). Those migrations
share a `set_compression` / `add_compression_policy` helper that no-ops when
TimescaleDB is absent. The two largest tables never received that helper.

`DataRetentionWorker` already reinstalls retention policies and chunk
intervals on every run. Compression is not part of that reconcile, so even
if a one-shot `ALTER TABLE` had been run on `demo`, a fresh tenant
provision would not get it.

GH #478 asked to establish *why* compression is off before turning it on.

## Why it is off

It was never installed. Evidence:

- `grep add_compression_policy elixir/serviceradar_core/priv/repo/migrations`
  hits only capacity-forecast and endpoint-inventory migrations. There is
  no compression DDL for `ocsf_network_activity` or `timeseries_metrics`.
- `DataRetentionWorker.reconcile_timescale_tables/1` calls
  `RetentionFence.reconcile_policy/2` (retention only),
  `set_chunk_interval/2`, and `drop_expired_chunks/2`. No compression.
- Chart `postInitApplicationSQL` and recent extension-handling work
  (`update-cnpg-pg18-and-search-extension-strategy`) do not set
  `timescaledb.compress`. A fresh provision of the current chart would
  reproduce `compression_enabled = false`.

This is an omission, not a recorded decision to keep the chunks
uncompressed.

## Ingest mutability (the historical UPDATE/DELETE caveat)

Compressed chunks historically restricted `UPDATE`/`DELETE`. On TimescaleDB
2.24 (what the CNPG image ships) DML on compressed chunks is supported but
still more expensive than on uncompressed chunks, so the ingest path must
not be an upsert-into-closed-chunks design.

Checked:

- `EventWriter.Processors.Telemetry` writes `timeseries_metrics` with
  `on_conflict: :nothing`.
- `EventWriter.Processors.Flows` writes
  `ocsf_network_activity` with `on_conflict: :nothing` (`EventWriter.Processors.Sweep`
  was a historical example here; that unregistered processor has been removed).
- No `UPDATE` / `Repo.update` / `on_conflict: {:replace, ...}` targeting
  either table showed up in core-elx.

Both tables are append-only. `ON CONFLICT DO NOTHING` against a unique key
that includes the time column does not rewrite a closed chunk: a duplicate
is discarded, a new timestamp lands in the open chunk.

`ocsf_events` *is* update-prone (`on_conflict: {:replace, ...}` from
anomaly disposition) and is **not** in this change.

## Goals / Non-Goals

- Goals:
  - Compression enabled and policy-backed on the two named hypertables,
    including on a database created from the current migrations.
  - Documented `compress_after` / `segmentby` / `orderby` per table.
  - Measured ratio and a query-latency check on `demo` before tenant
    values change.
- Non-Goals:
  - Compressing every hypertable.
  - Changing retention, chunk interval, or CAGG refresh windows.
  - Recompressing after a later `segmentby` change (pick once).

## Decisions

- **Decision: `compress_after` leaves the open chunk plus one closed chunk
  uncompressed.** `timeseries_metrics` chunks are 24h with 7-day retention
  → `compress_after = 2 days`. `ocsf_network_activity` chunks are 24h with
  90-day retention → `compress_after = 2 days`. Recent retrohunt / graphing
  windows stay on uncompressed chunks; everything older is compressed by
  the background job.
- **Decision: `segmentby` follows equality filters, not the primary key.**
  High-cardinality columns (src/dst IP, `series_key`) are not segment
  keys.
  - `timeseries_metrics`: `metric_type, metric_name, device_id` /
    `timestamp DESC`. Dashboard and SRQL filters are equality on those
    three; `device_id` nulls group together.
  - `ocsf_network_activity`: `partition, protocol_name` / `time DESC`.
    Both are low-cardinality. IPs stay out of `segmentby`.
- **Decision: migration plus worker reconcile, same shape as retention.**
  The migration is what a fresh database runs. The worker re-asserts
  `ALTER TABLE ... SET (timescaledb.compress, ...)` and
  `add_compression_policy(..., if_not_exists => true)` so a restored or
  hand-repaired cluster converges without a second migration. Both paths
  no-op without TimescaleDB, copying the existing helper.
- **Decision: first compression of existing `demo` chunks is a background
  catch-up, not a startup gate.** 91 + 8 uncompressed chunks will take
  wall time and CPU. The policy is installed; `timescaledb.jobs` /
  `job_stats` is how operators watch it. Do not `compress_chunk` in a
  loop from the migration.
- **Decision: tenant rollout is gated on `demo` numbers.** Record
  compressed/uncompressed bytes and a before/after of one representative
  SRQL flow query and one timeseries graphing query. No Helm default
  change is required — the policy lives in schema.

## Risks / Trade-offs

- **Background compression CPU on the primary.** Demo primary sits at 0.9
  cores p95 against 8 vCPU, so there is room. Tenant tiers with tighter
  CPU must be checked against `job_stats` before they inherit the
  migration by upgrading. Mitigation: `compress_after = 2 days` limits how
  much work is newly eligible each day after the catch-up.
- **Wrong `segmentby` is expensive to undo.** Changing it later means
  decompress + recompress. Mitigation: lock the keys above; if `demo`
  catch-up shows pathological segment counts, stop and revise before
  tenants upgrade.
- **Query latency on compressed chunks.** Columnar compressed chunks are
  usually faster for the analytic shape SRQL issues (time range + a few
  equality filters). Mitigation: the `demo` latency check is a go/no-go
  for tenant rollout, not a hope.

## Migration Plan

1. Land the migration and worker reconcile on a feature branch.
2. Roll `demo`, confirm `compression_enabled = true` and the policy row
   exists immediately (chunks compress asynchronously).
3. Watch `timescaledb.jobs` until a majority of eligible chunks report
   compressed; record ratio.
4. Run the two representative SRQL queries before/after; keep the numbers
   in the PR.
5. Tenant chart upgrades pick the migration up with the next release. No
  separate tenant flag.

Rollback: `remove_compression_policy` + `decompress_chunk` on remaining
compressed chunks. Do not ship a down migration that decompresses 80 GB
as part of `mix ecto.rollback`; document the decompress runbook instead.

## Open Questions

None that block the change. Tenant-tier CPU headroom is a rollout check,
not a design input.
