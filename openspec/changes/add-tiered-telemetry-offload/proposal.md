# Change: Tiered telemetry offload — export aging telemetry to object storage before retention drops it, with a transparent cold query path

## Why

Raw telemetry is deleted aggressively today: `otel_traces` after 3 days,
`timeseries_metrics`/sysmon after 7, `ocsf_events` after 14, `logs`/OTEL metric
points after 30, `ocsf_network_activity` after 90. Hourly continuous aggregates
keep 395 days of rollups, but raw-granularity history is simply destroyed by
`drop_chunks` — there is no archive tier and no way to answer "show me the raw
logs/spans/flows from six weeks ago". Deployments that provision object storage
(hosted tenants already get a per-tenant bucket) have nowhere to point it.

This change adds a tiering path: closed hypertable chunks are exported to
hive-partitioned Parquet on deployment-supplied object storage *before* the
retention machinery is allowed to drop them, a dedicated analytics PostgreSQL
instance (pg_duckdb, no TimescaleDB) serves queries over the archived Parquet
plus the recent hot rows, and SRQL routes raw-shape queries whose window
reaches below the hot retention window to that cold path — invisibly to the
user. When no cold-tier configuration is supplied, every behavior in this
change is inert and OSS deployments run exactly as today.

## What Changes

- **Cold schema registry** (core-elx): the single source of truth for
  offloadable tables — export column lists with canonical casts, Parquet
  partition layout, per-table hot/cold windows, analytics-head view DDL, and
  SRQL entity mapping. v1 tables: `logs`, `otel_traces`, `otel_metrics`,
  `otel_metric_points`, `timeseries_metrics`, `ocsf_events`,
  `ocsf_network_activity`.
- **Chunk export pipeline** (core-elx Oban + analytics head): per-chunk
  `COPY (SELECT …) TO 's3://…' (FORMAT parquet)` driven through the analytics
  head's DuckDB postgres scanner, verified, and recorded in a manifest table on
  the primary. A per-table **cold completeness frontier** advances only over
  contiguously verified chunks.
- **Offload-gated retention**: when the cold tier is configured,
  `DataRetentionWorker` and the retention-policy-installing migrations route
  through a shared fence — in-database TimescaleDB retention policies are
  removed for registry tables, and `drop_chunks` only drops chunks that are
  verified-exported, re-verified at drop time, and entirely below the frontier.
  A bounded pressure-relief policy (headroom budget, escalating alerts, chunk
  quarantine, operator-acknowledged emergency drop) prevents export stalls from
  becoming primary disk-full outages. **BREAKING** for cold-enabled deployments
  only: retention timing becomes export-gated; OSS default behavior unchanged.
- **Analytics query head**: a new, default-disabled Helm component deploying a
  small single-instance CNPG cluster from a new `serviceradar-cnpg-analytics`
  image (PostgreSQL 18 + pg_duckdb, **no** TimescaleDB/AGE/PostGIS), hosting
  schema-matched `platform.<table>` views that stitch recent hot rows (DuckDB
  postgres scanner against the primary, bounded by the frontier) with archived
  Parquet (`read_parquet`). The tenant primary's image, extensions, preload
  list, and configuration are untouched.
- **SRQL cold routing** (rust/srql + web-ng/core-elx): `translate/5` learns
  deployment-supplied cold-tier configuration; raw-shape queries whose resolved
  window extends below the hot window are emitted as cold-dialect SQL
  (partition-pruning predicates, deterministic tiebreakers, explicit NULLS
  ordering, registry-driven construct translation, fail-closed on
  untranslatable shapes) and executed on a dedicated `ColdRepo`. Stats and
  downsample queries keep routing to the in-database CAGGs (which already
  retain 395 days) — cold routing is raw-shape only in v1. Hot-only queries
  keep byte-identical plans. Head or object-store unavailability degrades to
  hot-only results with an explicit truncation notice.
- **Storage/retention telemetry**: per-table hot bytes, cold bytes, ingest
  bytes/day, frontier lag, and held-chunk gauges exposed on the existing
  web-ng `/metrics` endpoint so an external control plane can meter usage and
  project retention horizons.
- **Under-retained rollup alignment**: lengthen the CAGG retention windows that
  are shorter than their raw source's queryable ambition
  (`ocsf_events_hourly_stats` 24h, `traces_stats_5m` 14d, flow
  5m/proto/talkers/ports 30d) instead of exporting CAGGs; CAGG Parquet export
  is explicitly deferred until a cold window beyond 395 days is required.
- **CAGG refresh-window clamp (pre-existing data-loss bug, fixed here)**:
  empirically verified on the production image — `drop_chunks` plants
  invalidation entries, and any refresh covering a dropped region DELETES the
  materialized buckets. Several CAGGs refresh past their raw source's
  retention (metric hourlies 32d over 7d raw; `spans_red_1h`/`traces_stats_5m`
  over 3d raw), so their long-retention materializations are progressively
  destroyed today, cold tier or not. This change clamps the shipped refresh
  windows inside raw retention, adds a data-driven hazard alert to the
  retention worker (all deployments), and a stale-invalidation "loaded gun"
  alert on cold-configured ones. Consider cherry-picking the clamp migration
  as a standalone staging hotfix ahead of this change.
- **Per-table retention env completion**: `timeseries_metrics` gains its own
  retention environment variable, decoupled from the compile-time
  `:raw_metrics_retention_days` key it currently shares with the sysmon split
  tables — a projected window for the timeseries class would otherwise be
  silently ignored.
- **Supersedes `add-delta-metrics-lakehouse`** (unimplemented beyond
  validation): this change generalizes its SRQL-seam idea from metrics to all
  high-volume signals and replaces the JetStream→Delta writer + external DuckDB
  federation with offload-from-CNPG + Parquet + analytics head. Its
  write-throughput motivation is preserved as an explicit future lane: if the
  measured ingest rate ever exceeds the CNPG write path, a JetStream-side
  writer can be added that commits into the same manifest/layout contract. The
  parked `add-rust-tdengine-analytics` change and the `rust/metrics-delta-writer`
  skeleton are withdrawn/removed as part of this change.

## Impact

- Affected specs: **telemetry-tiering** (new capability), **srql** (ADDED),
  **cnpg** (ADDED), **tenant-capabilities** (ADDED),
  **kubernetes-network-policy** (ADDED).
- Affected code: `elixir/serviceradar_core` (registry, exporter worker,
  retention fence, manifest, S3 pruner, frontier bookkeeping, secrets
  reconciler), `elixir/web-ng` (ColdRepo, SRQL execution routing, truncation
  notice, storage gauges), `rust/srql` + `elixir/serviceradar_srql` NIF
  (cold-tier config input, routing, cold SQL dialect, cursor v3),
  `docker/images` + `MODULE.bazel` (new `serviceradar-cnpg-analytics` image),
  `helm/serviceradar` (analytics-head component, default off; network
  policies), `docker-compose.yml` (opt-in MinIO + local analytics-head
  profile for cold-tier development and CI), migrations (retention-policy
  fence helper, CAGG window alignment).
- New dependency: an S3 client in core-elx (object pruning, manifest↔bucket
  reconciliation); pg_duckdb (MIT) baked only into the new analytics image.
- Sibling change: `add-tenant-cold-telemetry-tier` in the `serviceradar-control`
  repo (bucket provisioning + credential custody, analytics-head chart values,
  per-table retention env projection, usage samples, retention-horizon
  projection UI, entitlements/pricing). This OSS change is self-contained and
  control-plane-independent: all behavior activates only on deployment-supplied
  configuration, per the tenant-capabilities pattern.
- Reconciliation notes: does **not** modify the cnpg image requirement heading
  touched by pending `update-cnpg-pg18-and-search-extension-strategy` (new
  analytics image is a separate ADDED requirement); does **not** modify the
  observability-signals headings touched by `fix-eventwriter-backpressure-hotpath`;
  `refactor-otel-signal-correlation`'s "OTel retention and chunk alignment"
  delta needs a cold-tier carve-out — it mandates drops within one policy
  period and warns when rows outlive configured retention, both of which a
  fenced, export-gated hold legitimately violates; whichever change lands
  second adds the exception (fence-managed holds are not retention failures).
- Approval is provisional on the Phase-0 decision-gate spikes (tasks §0):
  the load-bearing pg_duckdb mechanics (view-wrapped stitching, pushdown,
  cancellation, secret-based primary connection) are unverified until the
  spikes run; any spike failure re-opens the design per task 0.7.
- Explicit non-goals: ingest-path changes (JetStream + event_writer doctrine
  untouched), UPDATE/DELETE on archived data, cross-tenant analytics, CAGG
  export (>395d windows), replacing barman backups, sysmon split tables /
  survey / MTR / BMP offload (registry-ready, later), shared multi-tenant
  analytics heads.
