# Design — Tiered telemetry offload

## Context

- Instance-per-tenant model: each deployment owns a dedicated CNPG PostgreSQL 18
  cluster (custom Bazel image with TimescaleDB 2.24/AGE/PostGIS,
  `docker/images/cnpg_image.bzl`). All telemetry lands in `platform.*`
  hypertables via NATS JetStream + EventWriter; retention is owned by
  `ServiceRadar.Observability.DataRetentionWorker`
  (`elixir/serviceradar_core/lib/serviceradar/observability/data_retention_worker.ex`)
  which nightly (re)installs TimescaleDB retention policies **and** explicitly
  `drop_chunks`. Retention-policy DDL is *also* re-installed by migrations at
  every upgrade (e.g. `20260605210000_reconcile_observability_retention_chunks.exs`)
  — there are multiple policy mutation points, and the offload fence must cover
  all of them.
- SRQL is a translate-only Rust NIF (`rust/srql`, wrapped by
  `elixir/serviceradar_srql`); web-ng/core-elx execute the generated SQL via
  Ecto against the primary. Entity→table binding is by unqualified name +
  `search_path=platform`. Stats/downsample queries >6h already auto-route to
  hourly CAGGs (`rust/srql/src/query/cagg.rs`); raw listing queries never do.
  Cursors are HMAC-signed OFFSETs. Default lookback caps: 90d (raw), 395d
  (CAGG-eligible stats).
- pg_duckdb (MIT, v1.1.x, PG14–18) is production-adopted (Azure GA,
  PlanetScale) but **structurally incompatible with a TimescaleDB-loaded
  instance**: it calls `standard_planner()` directly (`pgduckdb_planner.cpp`),
  bypassing the planner hook where TimescaleDB initializes its BaserelInfo
  hash → deterministic SIGSEGV whenever the DuckDB path plans a query
  referencing any PG relation (duckdb/pg_duckdb#845, #963 — open >12 months;
  #963 reproduces with timescaledb merely loaded). Any design that embeds
  pg_duckdb in the tenant primary is therefore rejected on safety, not tuning.
- Hosted tenants already receive a per-tenant object-storage bucket (backups
  purpose) provisioned by the control plane; a second bucket purpose is cheap.
  Timescale's own tiered storage is exactly this UX but Tiger-Cloud-only —
  validation that the product shape is right and that we must build it ourselves.

## Goals / Non-Goals

- Goals:
  - Never lose raw telemetry to retention when a cold tier is configured:
    export-before-drop with verifiable durability.
  - Raw-granularity queries over the archived window through the same SRQL
    surfaces, without users knowing which tier served them.
  - Zero behavior change and zero new runtime dependencies when cold-tier
    configuration is absent (OSS default).
  - Tenant primary untouched: no new extensions, no preload change, no restart.
  - Per-signal storage/retention telemetry sufficient for an external control
    plane to project retention horizons.
- Non-Goals:
  - Ingest-path changes (JetStream/EventWriter doctrine stands; offload reads
    CNPG post-ingest).
  - Stats/downsample answers from Parquet in v1 (in-database CAGGs already
    retain 395d; cold routing is raw-shape only).
  - Mutating archived data; cross-tenant analytics; shared analytics heads;
    backup replacement; >395d stats windows (follow-up lane).

## Decisions

### D1. Topology: dedicated analytics query head; primary untouched
A second, small, single-instance CNPG cluster per deployment ("analytics
head") runs a new `serviceradar-cnpg-analytics` image: PostgreSQL 18 +
pg_duckdb, **without** TimescaleDB/AGE/PostGIS. It owns all DuckDB execution:
chunk exports, Parquet reads, and hot∪cold stitching. Crash blast radius is
contained to the cold path; the OLTP primary never loads new libraries.
- Alternatives rejected:
  - *pg_duckdb in the tenant primary* (original sketch): deterministic
    SIGSEGV with TimescaleDB loaded (#845/#963 — the hot∪cold view and
    `COPY (SELECT … FROM <pg table>)` are exactly the crashing shape;
    `force_execution=off` does not avoid it); per-backend memory
    (`duckdb.max_memory` defaults to 4096MB *per connection*), thread
    explosion, spill into PGDATA, preload rolling restart of every
    deployment.
  - *Same-name hot∪cold views in the primary*: EventWriter upserts
    (`ON CONFLICT` on `ocsf_events` etc.) cannot pass through views.
  - *pg_lake / pgduck_server sidecar*: best-in-class isolation and
    transactional Iceberg, but 8 months into OSS life, sidecar-in-CNPG
    unproven, TimescaleDB coexistence untested — revisit as a v2 engine.
  - *Shared multi-tenant analytics head*: rejected on the
    dedicated-cluster-per-tenant doctrine (tenant-cluster-provisioning),
    cross-cluster networking to every primary, and pg_duckdb blast radius
    spanning all tenants. Savings (~$20–40/mo/tenant vs ~$2–4 shared) are the
    revisit trigger, recorded here deliberately. Note: the tenant-isolation
    spec itself would *not* forbid it — the disqualifiers are the above.
  - *Elixir-side export (Explorer/Polars)* and *pg_parquet in the primary*:
    both viable export-only fallbacks; kept as documented break-glass paths
    (D5) — pg_parquet would reopen the primary image and preload list and
    still delivers no read path.

### D2. Format: hive-partitioned Parquet + manifest-in-primary as the commit protocol
Layout: `s3://<bucket>/cold/v1/<table>/date=YYYY-MM-DD/<chunk_id>[_<n>].parquet`,
zstd, rows sorted by (time, series/tiebreaker) for row-group pruning. No table
format (Delta/Iceberg/DuckLake) in v1: single writer, append-only, immutable
objects, partition-granular pruning — a transaction log adds a catalog service
(Iceberg) or an engine version we can't reach from pg_duckdb's bundled DuckDB
1.4.3 (Delta writes). **Atomicity lives in the manifest**, not the object
store: `platform.cold_chunk_exports` on the *primary* is the source of truth
(chunk, table, time range, object keys, rows, bytes, checksum, status,
verified_at). Objects are invisible to every reader until their manifest row
is `verified` (views and pruning are manifest/frontier-driven). Deterministic
object keys make re-export idempotent (overwrite). This manifest contract is
also the interface a future ingest-side writer must commit through
(supersession lane of `add-delta-metrics-lakehouse`).
- DuckLake noted as the most likely v2 upgrade (PG-as-catalog, 1.0 since
  2026-04) once pg_duckdb bundles a DuckDB ≥1.5.

### D3. Two boundaries, not one watermark
Per offloaded table:
- **Cold completeness frontier `F`**: all rows with `ts < F` are
  verified-durable in Parquet. The exporter advances `F` only over
  *contiguously* verified chunks. Target lag: `F ≈ now − export_lag`
  (default 48h) — export runs continuously, well before drop.
- **Hot drop boundary**: unchanged per-table hot retention window.
- **Overlap zone** `[drop boundary, F)`: rows exist in both tiers.

Stitching rule (analytics head views): Parquet branch `WHERE ts < B`,
hot branch (DuckDB postgres scanner against the primary) `WHERE ts >= B`,
where `B` is the head's per-table boundary value. Invariants:
1. `drop point ≤ B ≤ F` at all times.
2. Ordering: the exporter first writes `B` to the head and confirms it, and
   only then marks chunks ≤ `B` drop-eligible. Head unreachable ⇒ `B` stays
   stale-low ⇒ drops stall (safe direction). No gap is constructible.
3. `drop_chunks` requires: chunk entirely below `B`, manifest `verified`, and
   a drop-time re-verification (D4).

Because `F` trails `now` by only ~48h, the hot branch of any crossing query
streams at most ~48h of rows from the primary — bounded, not the whole hot
window. Queries whose window ends below `B` never touch the primary at all.

### D4. Export correctness against late writes and upserts
TimescaleDB chunks are never closed: late-arriving rows and upserts
(`ocsf_events` `ON CONFLICT … DO UPDATE` from anomaly disposition) mutate
already-exported chunks. Contract:
- Initial export at `chunk_end < now − export_lag`; row count + checksum
  recorded.
- **Overlap-zone refresh**: a daily pass re-compares chunk row counts (and a
  cheap aggregate for update-prone tables) against the manifest and re-exports
  drifted chunks. Update-prone tables (`ocsf_events`) are additionally
  re-exported unconditionally at drop time.
- **Drop-time re-verification**: immediately before `drop_chunks`, count-check
  again; mismatch ⇒ re-export, then drop.
- Residual, documented staleness contract: mutations that land between the
  final export and the drop are lost; mutations to rows already below the
  drop boundary land in freshly re-created chunks, which the standard
  export→verify→drop cycle picks up (new chunk id → new Parquet object; no
  overlap with the dropped chunk's rows).
- CAGG note (deferred lane): CAGG buckets are rewritten by refresh policies
  long after bucket time — any future CAGG export needs its own
  "closed = bucket_end < now − refresh_lag" rule.

### D5. Retention fence and pressure relief
- **Fence**: a shared policy-install helper becomes the only way retention
  policies are (re)installed — consumed by `DataRetentionWorker` *and* by
  migrations (the current migrations re-install policies unconditionally at
  upgrade; that path must consult the fence or un-exported chunks get eaten by
  the TimescaleDB bgw before the next nightly pass). When the cold tier is
  configured: in-DB policies for registry tables are **removed**, and each
  exporter run asserts none has reappeared (alert if so). CI check: any
  migration touching `add_retention_policy` on a registry table must go
  through the helper.
- **Two-phase disable**: turning the cold tier off is drain-then-re-arm —
  held chunks are exported or explicitly waived by an operator before
  policies are re-installed. Never an implicit flip back to dropping.
- **Pressure relief** (export stall must not become a primary disk-full
  outage — this platform has had exactly that incident class):
  - Headroom budget: `headroom_days = f(p95 ingest bytes/day, provisioned
    volume)` computed continuously; escalating alerts at 70/85/95% of budget
    via the storage gauges.
  - Poison-chunk quarantine: after N failed export attempts, skip + alert;
    quarantined chunks block frontier advance (contiguity) but not exports of
    other tables.
  - Break-glass export paths: documented manual pg_parquet-less fallback
    (app-side COPY to CSV/Parquet via the head once healthy, or Elixir-side
    Explorer export) for poison chunks.
  - Emergency floor: at a hard disk watermark (default 90%), an
    operator-acknowledged forced drop of the oldest held chunks is permitted
    (explicit, logged, alerting); the default posture is always hold+alert.
- Correctness does **not** depend on Oban scheduling order between exporter
  and retention worker — the drop gate alone enforces it (do not "fix"
  perceived races by coupling the workers).

### D6. Export mechanics through the analytics head
`duckdb.query($$COPY (SELECT <registry column list with canonical casts> FROM
postgres_scan(...) WHERE ts >= $lo AND ts < $hi) TO 's3://…' (FORMAT parquet,
COMPRESSION zstd)$$)` per chunk, driven by core-elx over `ColdRepo`.
- Primary protection: DuckDB postgres scanner pinned to
  `pg_connection_limit 1–2`; dedicated read-only role on the primary
  (registry tables + manifest only) with role-level `statement_timeout`,
  `idle_in_transaction_session_timeout`, TCP keepalives; backfill paced one
  chunk at a time, off-peak, with an xmin-age monitor and abort threshold
  (long snapshots block vacuum on high-churn tables —
  `flow_process_attribution_current` history says this is real).
- **Phase-0 spike (approval gate)**: verify predicate pushdown through the
  hypertable *parent* via postgres scanner (ctid-partitioned scans size by
  relpages, which is ~0 on the parent). Fallback (also spiked): target chunk
  relations in `_timescaledb_internal` directly — safe for v1 scope since no
  registry table is compressed.
- **Phase-0 spike**: `COPY … TO s3` stability for this exact statement family
  (open pg_duckdb #1056 is a SEGV in a cousin shape — blast radius is the
  head only, but export availability matters).
- Verification: `read_parquet` count vs primary chunk count (+ checksum
  column aggregate); performed within the same off-peak window to avoid
  re-scanning at peak.

### D7. Cold query path and SRQL routing (M2)
- Analytics head hosts schema-matched `platform.<table>` views per registry
  entry (generated from the registry; regenerated on schema migration — CI
  drift check). Referenced dimension tables (`ocsf_devices`, flow-attribution
  lookup tables) get same-name postgres-scanner views — **not** postgres_fdw:
  a query mixing an FDW relation with `read_parquet` can execute in neither
  engine; the DuckDB postgres scanner is the only hot-branch mechanism.
- SRQL `translate` gains a cold-tier config input (enabled entities, per-table
  `B`/hot windows, cold window caps) and returns route metadata. Routing rule:
  raw-shape queries (row listing, point lookups with an absolute time hint,
  sub-6h raw graphing) on registry entities whose resolved window extends
  below the hot window ⇒ `route=cold`. Stats/downsample keep CAGG routing on
  the primary (≤395d) unchanged. Queries with no time filter stay hot-only
  unless the caller supplies an absolute hint — the trace detail view passes
  the summary's start time (summaries outlive raw spans), which fixes the
  `:spans_expired` case *and* gives partition pruning.
- Cold SQL dialect rules (registry-encoded, fail-closed):
  - redundant `date=` partition predicates derived from the resolved window;
  - a unique tiebreaker appended to every ORDER BY + explicit
    `NULLS FIRST/LAST` matching PG semantics;
  - construct translation for PG-isms DuckDB lacks (`#>>`,
    `jsonb_build_object`, `try_inet`/`<<=`/cidr casts, `WITHIN GROUP`
    percentile shapes, `E''` strings); untranslatable shape ⇒ typed
    "not available for archived history" error, never a raw DuckDB error;
  - DuckDB-native `time_bucket` is available (no polyfill); JSON operators
    map to DuckDB JSON functions over the exported JSON-text columns.
- Execution: `ColdRepo` (Ecto, pool_size 2–4, statement_timeout 60s default).
  Head memory request = `pool_size × duckdb.max_memory + PG overhead + spill
  headroom` — sized in chart values, spill on a dedicated ephemeral volume
  with `duckdb.max_temp_directory_size` set.
  **Phase-0 spike**: PG `statement_timeout` must actually cancel in-flight
  DuckDB executions on the head; otherwise enforce cancellation client-side.
- Fail-soft: ColdRepo down / object store down ⇒ execute hot-only and attach
  an explicit truncation notice (the trace UI `:spans_expired` pattern
  generalized). The hot tier never errors because the cold tier is sick.
- Pagination: cursors become v3 embedding the resolved absolute window (pages
  must not re-resolve `now`/`B`); deep-offset cold pages re-scan Parquet —
  cold route gets a lower max-offset cap.
- Background SRQL (core-elx `SRQLRunner`: anomaly, capacity, seasonal jobs) is
  pinned hot-only via the existing `mode` parameter — pipelines must never
  couple to head availability.
- Consistency contract (documented): the overlap zone is eventually
  consistent — late rows/upserts appear on the cold path after the next
  refresh pass (≤24h); rows are never missing from *both* branches (D3
  invariants).

### D8. Secrets and connectivity
- Object-store credentials: DuckDB `SECRET` on the head, created and
  continuously re-asserted by a core-elx reconciler from the mounted K8s
  secret (rotation-safe; nothing depends on a one-shot bootstrap job).
  Per-provider `url_style`/endpoint quirks (path-style stores, checksum
  behaviors) are registry config.
- Primary connectivity: DuckDB postgres-type `SECRET` (or head-local
  credential object), never DSN literals inside view DDL (no passwords in
  `pg_views`). Rotation runbook + integration test are deliverables.
- NetworkPolicies: head→primary :5432 (read-only role), head→object-store
  egress, core/web-ng→head; nothing else reaches the head.

### D9. Cold retention & pruning
Window-driven: per-table cold windows from deployment config (absent ⇒ no
pruning beyond manifest hygiene). core-elx prunes objects manifest-first-read,
**objects before manifest rows** (orphaned manifest rows are harmless;
orphaned objects leak cost), plus a periodic manifest↔bucket reconciliation
sweep (handles S3 eventual-consistency and aborted-multipart debris; bucket
lifecycle rule `AbortIncompleteMultipartUpload` requested at provisioning
where the provider honors it). Quota-driven eviction (prune-to-bytes with a
cross-signal eviction order) is a documented follow-up, not v1.

### D10. Storage/retention telemetry
Always-on (cold tier or not): per-registry-table hot bytes
(`hypertable_detailed_size`) and ingest-bytes/day EMA gauges. Cold-tier
additional gauges: cold bytes (manifest), frontier lag, held/quarantined chunk
counts, headroom-budget consumption, oldest-available timestamp per table
(measured lookback). Exposed on the existing web-ng `/metrics` endpoint (the
channel external control planes already scrape) + an authenticated JSON admin
endpoint. Hot-size projection consumers must subtract the non-telemetry
baseline (`pg_database_size` − tracked hypertable bytes) — exported as its own
gauge so projections don't systematically overestimate.

### D11. Gating (tenant-capabilities pattern)
All OSS behavior keys off deployment-supplied configuration: when the
cold-tier configuration (bucket, credentials secret name, head connection,
entity windows) is absent, the exporter never schedules, the fence is inert,
SRQL routing is disabled, and the Helm analytics-head component renders
nothing. No plan names or commercial policy in OSS code or specs. The runtime
consumes per-table retention envs (`SERVICERADAR_<TABLE>_RETENTION_DAYS`) —
these exist for six of the seven v1 tables; `timeseries_metrics` currently
rides the shared compile-time `:raw_metrics_retention_days` key (also used by
the sysmon split tables) and gains its own decoupled env as part of M1. The
scalar `SERVICERADAR_RETENTION_HOT_DAYS` is deprecated, never consumed
(mapping plan→per-table windows is external policy). Retention-window
*shortening* on a cold-enabled deployment additionally requires the frontier
to cover the newly-dropped range first.

### D12. Image and operator
`serviceradar-cnpg-analytics`: new Bazel `oci_image` following
`cnpg_image.bzl` layer patterns — upstream CNPG PG18 base + pg_duckdb layer
(+ `libstdc++6` in the runtime overlay: libduckdb is C++-heavy and the
existing glibc overlay omits it; this exact class caused the GLIBC_2.38
crash-loop incident). CI boot-smoke test (start PG, `CREATE EXTENSION
pg_duckdb`, run a `read_parquet`) gates every digest pin bump. Head GUC
posture: `duckdb.postgres_role` bound to a dedicated role,
`duckdb.max_memory` 1–2GB, `duckdb.threads` 2,
`duckdb.disabled_filesystems='LocalFileSystem'`, community extensions off,
autoinstall off with `httpfs`/`postgres` pre-packaged. CNPG operator v1.24.1
runs it fine; the head is the ideal canary for the overdue operator upgrade
(adjacent task, not blocking).

## Risks / Trade-offs

- pg_duckdb export-statement crash class (#1056 cousin) → contained to the
  head; Phase-0 spike + quarantine + break-glass path (D5, D6).
- Hypertable-parent pushdown unverified → Phase-0 spike; chunk-relation
  fallback (D6).
- Type fidelity across tiers (`jsonb`→JSON text, `timestamptz`→UTC,
  numeric bounds, Arrow column typing for dashboard frames) → registry
  canonical casts + golden hot/cold parity suite asserting at the Arrow layer
  (M2 gate).
- S3 request amplification (footer reads across hundreds of objects) →
  partition predicates from SRQL + optional manifest-driven file lists;
  compaction job (monthly partition rewrite) as follow-up.
- Head is a SPOF for cold queries → fail-soft contract (D7); exports resume
  where they left off (manifest); single-instance is acceptable because no
  unique state lives on the head.
- Ecosystem churn (pg_duckdb pace, DuckLake pull) → boring Parquet + manifest
  keeps the query engine swappable; export format outlives any engine choice.
- Per-deployment cost of an always-on head (~2.5–4GB RAM, 0.5–1 vCPU, small
  PVC + spill volume) exceeds the object-storage COGS it serves → enablement
  is a deployment decision (external control planes gate by plan); hibernation
  /lazy-start recorded as a follow-up cost lever.

## Migration Plan

- **Phase 0 — decision-gate spikes** (block approval→implementation):
  postgres-scanner-in-view pushdown both branches; hypertable-parent vs
  chunk-relation scans; statement-timeout cancellation; COPY-to-S3 stability;
  object-store compat matrix (Linode/Ceph-RGW; path-style stores);
  DuckDB NULLS/collation vs PG ordering verification (cluster locale check).
- **M1 — offload + gated retention + telemetry** (shippable alone; no SRQL/NIF
  changes): registry, image, head chart component, exporter, manifest,
  frontier, fence (worker + migrations), pressure relief, pruning, gauges,
  CAGG window alignment migration. Verification hardened (checksums) because
  the query-back path doesn't exist yet. Dual-running: retention behavior on
  a cold-enabled canary first.
- **M2 — transparent cold queries**: NIF config input + routing + cold SQL
  dialect + ColdRepo + fail-soft + cursor v3 + parity suite + trace-detail
  time hint. Rollout per entity family (logs → traces → flows → events →
  metric points), each behind the registry.
- **Rollback**: M2 is config-off per entity; M1 disable is the two-phase
  drain (D5); un-exported data is never at risk from rollback by
  construction.

## Open Questions

- Chunk-relation export fallback vs parent-scan: decided by Phase-0 spike.
- Compaction cadence/shape (monthly rewrite vs manifest file-lists only) —
  follow-up sized by observed object counts.
- DuckLake adoption trigger (pg_duckdb bundling DuckDB ≥1.5 + DuckLake 1.1
  maturity) — revisit at M2 completion.
- Whether `service_status`/sysmon-split tables join the registry once their
  writer status is clarified (schema research flags them read-legacy).
