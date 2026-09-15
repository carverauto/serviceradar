# Change: Analytics-store drivers — Timescale or pg_duckdb/Parquet behind one interface

GitHub: [carverauto/serviceradar#477](https://github.com/carverauto/serviceradar/issues/477)

## Why

Time-series hypertables are ~74% of a ServiceRadar database and they sit on
the most expensive storage we buy. Measured on `demo`:

```
139 GB  TimescaleDB hypertables   74%
 49 GB  relational / current-state 26%
188 GB  total
```

Two tables dominate: `ocsf_network_activity` (82 GB, 90 days) and
`timeseries_metrics` (51 GB, **7 days**). Seven days is not the product
window — it is what block storage affords. Hosted tenants replicate CNPG
3×, so every logical GB is $0.30/GB-mo of block vs $0.02/GB-mo of object
storage. A year of telemetry as Parquet is near $10/mo; the same year as
hot hypertables is ~$900/mo.

`add-tiered-telemetry-offload` started this problem from the other end:
keep writing CNPG, export closed chunks to Parquet, stitch hot∪cold through
postgres_fdw on a pg_duckdb analytics head, and gate `drop_chunks` on a
completeness frontier. That is a working design and several spikes already
passed, but it is more machinery than the product needs if the configured
analytics driver *is* DuckDB. The write path should not go through a
hypertable just to be copied out of it.

Two deployments make a single backend the wrong answer:

- **carverauto `demo`** runs CNPG on Longhorn. Random hypertable IO is
  already the tax. Object storage is the right place for append-only
  telemetry.
- **farm01** has no object-storage bucket provisioned. It still needs
  working analytics, on Timescale today and on local-NVMe Parquet later.

Operators pick the driver in Helm / Compose. SRQL, EventWriter, and the
dashboards do not.

Sibling: `enable-timeseries-hypertable-compression` (GH #478) ships first
and shrinks the hypertables that the Timescale driver still owns.

## What Changes

- Introduce an **analytics-store interface** (Elixir behaviour + SRQL
  dialect flag) with two query/write drivers:
  - `timescale` — today's CNPG hypertables (default; OSS, farm01, anyone
    without object storage or a local Parquet volume).
  - `pg_duckdb` — a dedicated analytics-head Postgres (pg_duckdb, no
    TimescaleDB) over hive-partitioned Parquet. When this driver is
    selected for a table, EventWriter writes Parquet through that head;
    the table is no longer a CNPG hypertable write target.
- Under the pg_duckdb driver, **Parquet storage is itself a backend**:
  `s3` (Akamai / MinIO / any S3-compatible bucket) or `filesystem`
  (hostPath / local NVMe / a dedicated PVC). Spill (`temp_directory`) is
  always an `emptyDir` on the node's local disk, never the Parquet
  volume, with an explicit `memory_limit`.
- **pg_duckdb is the DuckDB runtime.** SRQL already emits SQL; Ecto /
  Postgrex already talks to Postgres. The Hex libraries (duckdbex, Dux,
  QuackDB, quack_lake) are not adopted. pg_duckdb stays off the Timescale
  primary (open SIGSEGV with TimescaleDB loaded — pg_duckdb #845/#963).
- SRQL grows a `postgres | duckdb` dialect at the existing per-entity
  codegen seam. Result shape is unchanged. Stats/downsample on the
  pg_duckdb driver aggregate over Parquet rather than Timescale CAGGs.
- JetStream-first ingest is unchanged. EventWriter remains the single
  writer after the stream; it writes through the store interface.
- **Supersedes `add-tiered-telemetry-offload`.** Reuse the analytics
  image, Helm `analyticsHead` skeleton, cold schema registry (as the
  table inventory), GUC posture, and the proven `COPY ... TO parquet`
  path. Drop completeness-frontier bookkeeping, postgres_fdw hot∪cold
  views, export-gated retention, and SRQL cold-vs-hot routing. Do not
  archive-apply that change's spec deltas.

**BREAKING** only for a deployment that sets `analyticsStore.driver=pg_duckdb`
for a table: that table's raw rows stop landing in CNPG. Default remains
`timescale`, so OSS and farm01 are unchanged until they flip the value.

## Impact

- Affected specs: **analytics-store** (new), **srql**,
  **observability-signals**, **cnpg**, **docker-compose-stack**,
  **kubernetes-network-policy**.
- Affected code:
  - `elixir/serviceradar_core` — `AnalyticsStore` behaviour, Timescale and
    pg_duckdb drivers, EventWriter write routing, schema registry reuse,
    retention no-op for tables the pg_duckdb driver owns.
  - `elixir/web-ng` — SRQL execution picks primary Repo vs AnalyticsRepo
    from the driver + entity.
  - `rust/srql` + `elixir/serviceradar_srql` — dialect input, DuckDB SQL
    for analytics-store entities, CAGG bypass when dialect is duckdb.
  - `helm/serviceradar` — `analyticsStore` values, analytics-head
    component (already present, default off), emptyDir spill, filesystem
    vs S3 wiring.
  - `docker-compose` — opt-in profile (MinIO or local Parquet dir +
    analytics head).
  - Existing `docker/images/analytics_image.bzl` / Helm
    `cold-analytics-head.yaml` reused, not replaced.
- New Hex/NIF dependency: none. pg_duckdb stays in the analytics image.
- Sibling: `enable-timeseries-hypertable-compression` (GH #478) is
  independent and should merge first.

## Relationship to earlier lakehouse work

- `add-delta-metrics-lakehouse` (archived 2026-08-07) wanted Delta + a
  Rust writer + DuckDB federation with CNPG. Same problem, heavier format.
  Parquet + a manifest-or-directory layout is enough for a single writer.
- `add-tiered-telemetry-offload` (pending) is the export-from-CNPG design.
  This change replaces it. Keep the image, the head, the registry, the
  COPY-to-Parquet spike results; drop the stitch.
