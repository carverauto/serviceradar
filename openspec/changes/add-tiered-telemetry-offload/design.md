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
**Staging → verify → publish (the commit protocol's object half).** Exports
never write the published key directly: a COPY is non-preemptible and can
leave a complete-but-truncated object (spike 0.3), so writing straight to the
key readers glob would make corrupt data instantly query-visible — and a
re-export would do it to a key that was previously good. Exports land under
`cold/v1/<table>/_staging/`, verification runs against that object, and only a
verified object is server-side copied onto the published key. Object writes
are atomic per key, so readers see the previous good object or the new good
one, never a partial. Readers glob `date=*/` only, which is what makes
"unverified objects are never readable" true for readers and not just for the
manifest. (A verified-manifest-key file list instead of a glob is the stronger
form — it would also hide tombstoned-but-not-yet-deleted objects — and is
tracked as review finding F04's remainder.)

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

### D6. Export mechanics through the analytics head (AMENDED per Phase-0)
The DuckDB `postgres` extension cannot run inside pg_duckdb ("libpq is
incorrectly linked to backend functions") — the mechanism is **postgres_fdw**:
pg_duckdb executes FDW foreign tables inside DuckDB plans
(`PGDUCKDB_POSTGRES_SCAN`) with absolute-literal predicates pushed down to the
primary, where TimescaleDB does native chunk exclusion (proven by exact tuple
accounting, spike 0.1). Export per chunk, driven by core-elx over `ColdRepo`:
`COPY (SELECT <registry column list with canonical casts> FROM
fdw.<table> WHERE ts >= $lo AND ts < $hi) TO 's3://…' (FORMAT parquet,
COMPRESSION zstd)`.
- **Connection contract (spike 0.2)**: SERVER options `fetch_size '1000'`
  (measured sweet spot, ~86–112k rows/s; 10000 regresses),
  `connect_timeout '5'`, `tcp_user_timeout '60000'`, `keepalives_idle '30'`,
  `keepalives_interval '10'`, `keepalives_count '3'` (libpq option names, not
  GUC names). Primary role `cold_reader`: SELECT-only on registry tables +
  manifest, role-level `statement_timeout`/`idle_in_transaction_session_timeout`,
  `CONNECTION LIMIT 2–4` (exhaustion = typed SQLSTATE 08001 → backoff-retry).
  Exports are single-connection, cursor-paced — gentle on the primary.
- **Exports are non-preemptible (spike 0.3 — hard rule)**: interrupting an
  in-flight `COPY … TO s3` (statement_timeout, pg_cancel, pg_terminate)
  yields a corrupt COMPLETED object, a poisoned session (including silent
  loss of the DuckDB S3 secret), or a postmaster SIGABRT on the head.
  Therefore: exporter sessions run `statement_timeout=0`; nothing ever
  cancels an exporter COPY; bounding comes from **input sizing** (≤1 chunk /
  ≈250MB output per COPY, observed seconds-to-tens-of-seconds); a watchdog
  alerts on overrun but never cancels; every exporter session is short-lived
  and discarded after any error; the head being dedicated (D1) makes the
  worst case (postmaster crash-recovery, <1s) product-invisible.
- **xmin discipline (spike 0.2)**: each COPY pins `backend_xmin` on the
  primary for its whole runtime — chunk-sized units bound vacuum-horizon
  holdback; backfills iterate units, never one giant COPY.
- Data addressing: hypertable **parent + absolute UTC range** only — chunk
  relations are never targeted directly (slower, DDL churn, unstable names,
  breaks under future columnstore compression; spike 0.2e).
- **Verification pair (spike 0.2, gates manifest commit)**: computed
  identically on the primary and via `read_parquet`:
  `count(*)`, `min/max` epoch-microseconds, `count(DISTINCT <tiebreaker>)`,
  `sum(length(text col))`, and a 60-bit-md5 content sum over a stable
  serialization (epoch_us + key columns + `floor(value*1e6)::bigint` for
  floats). Bans in checksum serializations: raw float `::text` (PG `1` vs
  DuckDB `1.0`), `round()` (divergent halfway modes), `hashtext()`
  (PG-only), timestamp text. Detects both row loss and content mutation
  (proven). Object existence proves nothing (spikes 0.3/0.4): a "completed"
  object may be truncated — only the verification pair admits a manifest row
  to `verified`, and unmanifested objects are garbage-collected.

### D7. Cold query path and SRQL routing (M2) (AMENDED per Phase-0)
- Analytics head hosts schema-matched `platform.<table>` views per registry
  entry (generated from the registry; regenerated on schema migration — CI
  drift check): Parquet branch (`read_parquet`, exposing the hive partition
  column) ∪ **postgres_fdw** foreign table for the hot branch. Spike 0.1
  proved the whole stitched query executes in one DuckDB plan with the query
  predicate intersected into BOTH branches and pushed down to the primary
  (the earlier "FDW can't mix with read_parquet" claim was wrong). Referenced
  dimension tables (`ocsf_devices`, flow lookup tables) are same-name FDW
  foreign tables. The staging-table variant remains a documented fallback if
  FDW-in-DuckDB regresses upstream.
- SRQL `translate` gains a cold-tier config input (enabled entities, per-table
  `B`/hot windows, cold window caps) and returns route metadata. Routing rule:
  raw-shape queries (row listing, point lookups with an absolute time hint,
  sub-6h raw graphing) on registry entities whose resolved window extends
  below the hot window ⇒ `route=cold`. Stats/downsample keep CAGG routing on
  the primary (≤395d) unchanged. Queries with no time filter stay hot-only
  unless the caller supplies an absolute hint — the trace detail view passes
  the summary's start time (summaries outlive raw spans), which fixes the
  `:spans_expired` case *and* gives partition pruning.
- Cold SQL dialect rules (registry-encoded, **allowlist-based** — spike 0.1
  found PG `~` regex silently returns different results under DuckDB
  (partial-match vs full-match), so fail-closed cannot be error-catch-based;
  every allowed construct is certified by a differential PG-vs-DuckDB
  execution test):
  - redundant `date=` hive-partition predicates derived from the resolved
    window — mandatory: timestamp predicates alone prune row groups but
    never files (spike 0.1c);
  - ordering contract (spike 0.6): every sort key gets explicit direction
    AND explicit `NULLS FIRST/LAST` (PG defaults spelled out), every ORDER BY
    terminates in the registry tiebreaker (DuckDB parallel scans are
    non-deterministic on ties — 5 runs / 3 orders without one), time
    predicates are absolute instants with explicit UTC offset;
  - construct translation for PG-isms (`#>>`, `jsonb_build_object`,
    `try_inet`/`<<=`/cidr casts, `E''` strings; `WITHIN GROUP` percentiles
    verified working); unlisted shape ⇒ typed "not available for archived
    history" error, never a raw DuckDB error;
  - DuckDB-native `time_bucket` is available (no polyfill); JSON operators
    map to DuckDB JSON functions over the exported JSON-text columns;
  - cancellation classification matches on error MESSAGE, not SQLSTATE —
    DuckDB-path timeouts/cancels surface as XX000 "Query cancelled", not
    57014 (spike 0.3).
- Collation (spike 0.6): the head database MUST be initdb'd
  `localeCollate/localeCType: C` (the primary already is, via CNPG operator
  defaults; the stock pgduckdb image is en_US.utf8). DuckDB always sorts
  binary/codepoint — C collation matches it exactly; no per-query COLLATE
  pinning is viable or needed. Startup/CI guard asserts
  `pg_database.datcollate='C'` on both (query `pg_database`, not
  `SHOW lc_collate` — removed in PG18).
- Execution: `ColdRepo` (Ecto, pool_size 2–4, statement_timeout 60s default).
  Head memory request = `pool_size × duckdb.max_memory + PG overhead + spill
  headroom` — sized in chart values, spill on a dedicated ephemeral volume
  with `duckdb.max_temp_directory_size` set.
  **Phase-0 spike**: PG `statement_timeout` must actually cancel in-flight
  DuckDB executions on the head; otherwise enforce cancellation client-side.
- Fail-soft: ColdRepo down / object store down ⇒ execute hot-only and attach
  an explicit truncation notice (the trace UI `:spans_expired` pattern
  generalized). The hot tier never errors because the cold tier is sick.
  Interactive timeout contract (spike 0.3): all cold SELECT shapes (parquet,
  FDW, stitched, local) are bounded by `statement_timeout` with ≤0.2s
  overshoot and by `pg_cancel_backend` within ~35ms; ColdRepo discards a
  session after any DuckDB error (errored sessions can silently lose their
  S3 secret and fall back to public endpoints). `duckdb.postgres_role` must
  be granted to the ColdRepo role (non-superusers are otherwise refused
  DuckDB execution); memory/threads/spill GUCs are superuser-only and set
  cluster-wide in the chart; spill can transiently reach ~12× the memory cap
  — PGDATA headroom and `duckdb.max_temp_directory_size` are sized for it.
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

### D8. Secrets and connectivity (AMENDED per Phase-0)
- Both credential kinds live as PG catalog objects on the head (spike 0.1d):
  the S3 secret (`duckdb.create_simple_secret` is itself stored as a dummy
  foreign server + user mapping, re-materialized into each session's DuckDB
  as a memory-only secret) and the primary connection (postgres_fdw SERVER +
  USER MAPPING for `cold_reader`). One reconciler story covers both — and it
  must be a full OWNER, not an asserter (spike 0.5): enumerate
  `pg_foreign_server`, `DROP SERVER … CASCADE` stale/duplicate secrets before
  re-creating (`create_simple_secret` accumulates `_1/_2/…` duplicates with
  ambiguous same-scope resolution and has no delete function), and always
  scope secrets to the bucket. No DSN literals inside view DDL — views
  reference FDW tables; passwords stay in user mappings.
- Scope/endpoint misconfiguration makes DuckDB silently fall back to public
  AWS endpoints (spike 0.5d) — the head's egress NetworkPolicy is the
  backstop, and the reconciler alerts on any resolution outside the
  configured endpoint.
- Per-provider `url_style`/endpoint quirks (path-style stores, checksum
  behaviors) are registry config. Rotation runbook + integration test are
  deliverables.
- NetworkPolicies: head→primary :5432 (read-only role), head→object-store
  egress, core/web-ng→head; nothing else reaches the head.

### D9. Cold retention & pruning (AMENDED per Phase-0)
Window-driven: per-table cold windows from deployment config (absent ⇒ no
pruning beyond manifest hygiene). Prune ordering is **tombstone-first**
(spike 0.5: readers using manifest-driven explicit file lists hard-error on
missing keys): mark manifest rows `pruned` (readers exclude) → delete objects
(including noncurrent versions) → GC manifest rows. The periodic
manifest↔bucket reconciliation sweep OWNS multipart-debris cleanup directly
via ListMultipartUploads/AbortMultipartUpload — bucket lifecycle rules are
requested at provisioning but must be verified after PUT and never trusted
(MinIO silently drops `AbortIncompleteMultipartUpload` from otherwise-valid
configs). Bucket versioning posture is provisioning-owned: unversioned, or a
`NoncurrentVersionExpiration` rule — idempotent re-export on a versioned
bucket otherwise accumulates full noncurrent copies (spike 0.4). Quota-driven
eviction (prune-to-bytes with a cross-signal eviction order) is a documented
follow-up, not v1.

### D10. Storage/retention telemetry (ingest rate amended)
Always-on (cold tier or not): per-registry-table hot bytes
(`hypertable_detailed_size`) and ingest-bytes/day gauges. **Ingest rate is
derived from the on-disk size of CLOSED chunks in a trailing window, not
from sampling table size over time**: retention drops and offload shrink a
hypertable, so a size delta reads as negative ingest exactly on the tables
the projection cares about. Closed-chunk sizes only ever reflect data that
arrived (the still-filling newest chunk is excluded, since its size
understates the rate). This is the `rate_s` input the control-plane horizon
math consumes. Cold-tier
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
`duckdb.disabled_filesystems='LocalFileSystem'` (verified on pg_duckdb
1.1.0: this blocks local file reads/writes from DuckDB while leaving S3
`COPY` **and query spill** fully working — so the lockdown is free),
community extensions off, autoinstall off with `httpfs` pre-packaged.
`duckdb.postgres_role` must name the query role: without it non-superusers
are refused DuckDB execution outright. CNPG operator v1.24.1
runs it fine; the head is the ideal canary for the overdue operator upgrade
(adjacent task, not blocking).

### D13. Continuous aggregates across retention and offload (verified 2026-07-16)
CAGGs are structurally independent of the cold tier: buckets materialize from
hot raw within minutes of ingest (refresh policies run every 5–10 minutes),
live in their own materialization hypertables under their own retention
(90–395d), and pre-watermark reads NEVER touch raw (verified: identical
results with real-time aggregation on and off after raw drops). Offload
happens at drop time, long after materialization — so every CAGG-dependent
view and SRQL stats route keeps working unchanged, and the cold tier needs
no CAGG participation for ≤395d stats.

The hazard is refresh, not reads — empirically verified on TimescaleDB
2.24.0 (the production image):
- `drop_chunks` itself writes invalidation-log entries covering every
  dropped chunk (one per chunk); the dropped region is poisoned before any
  late write.
- Any refresh whose window covers a poisoned region — manual OR the policy
  path (`run_job`) — recomputes those buckets from now-empty raw: buckets
  are DELETED, or replaced by late-row-only aggregates.
- Clamping refresh windows protects but only defers: pending invalidations
  persist indefinitely in `continuous_aggs_materialization_invalidation_log`
  (any refresh sweeps+merges them there, even disjoint no-op refreshes) and
  detonate on the first covering refresh.

**Pre-existing production bug found by this verification**: the metric
hourly CAGGs refresh with `start_offset='32 days'` over raw retained 7 days
(`spans_red_1h`/`otel_metrics_hourly_stats` 32d over 3d/30d raw;
`traces_stats_5m` 7d over 3d) — the destructive configuration exactly. Their
395/90-day retention promises are being progressively voided as raw ages
out, independent of the cold tier.

Decisions:
1. Migration 20260716210000 clamps every shipped refresh window strictly
   inside its raw source's retention (hourlies 32d→5d over 7d raw;
   spans_red_1h/traces_stats_5m→1d over 3d raw; otel_metrics_hourly_stats
   32d→28d over 30d raw). Wiped history is not resurrectable from raw; on
   cold-configured deployments it becomes repairable from Parquet
   (follow-up tooling).
2. `RetentionFence.cagg_refresh_hazards/1` — data-driven guard joining the
   Timescale jobs catalog (refresh vs retention policies) plus configured
   hot windows for fenced registry tables; `DataRetentionWorker` alerts on
   every run. Runs on ALL deployments (the hazard is not cold-specific) and
   catches env-tuned drift the static migration can't.
3. `RetentionFence.stale_invalidations/0` — exporter alerts on pending
   invalidation entries older than the hot boundary (the standing
   "loaded gun" signal).
4. Resurrection chunks from late writes widen invalidations; the clamped
   windows keep policy refreshes away from them, and the exporter re-exports
   the late rows to Parquet (D4) — cold captures what the CAGG can no longer
   safely absorb.

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

- **Phase 0 — decision-gate spikes: COMPLETE (2026-07-16, all six
  PASS-with-constraints).** Run against a live stack (real serviceradar-cnpg
  image + pgduckdb 18-v1.1.1 + MinIO, 5.2M seeded rows across 72 chunks).
  Verdicts, folded into D6–D9 above:
  - 0.1 stitching: DuckDB `postgres` extension is unusable inside pg_duckdb
    (libpq linkage) — **postgres_fdw-in-view is the mechanism** for both
    query stitching and exports; predicate pushdown + remote chunk exclusion
    proven by tuple accounting; hive `date=` predicates mandatory for file
    pruning; PG `~` regex silently diverges ⇒ allowlist dialect.
  - 0.2 export: fetch_size 1000 (~100k rows/s), libpq-named keepalive SERVER
    options, engine-stable verification pair (count/epoch-us/distinct/
    length-sum/60-bit-md5) proven to detect loss AND mutation; whole-COPY
    xmin pinning ⇒ chunk-sized units; parent+absolute-range only.
  - 0.3 cancellation: SELECT shapes bounded by statement_timeout (≤0.2s
    overshoot; XX000 not 57014); **COPY is non-preemptible and interrupts
    are destructive** (corrupt completed objects, poisoned sessions,
    SIGABRT) ⇒ exporter never cancels, input-sized units, discard-on-error
    sessions; upstream issues to file.
  - 0.4 stability: 15+ COPYs, zero segfaults on happy path; idempotent
    same-key overwrite holds; verification must be a real parquet read;
    OOM = fast whole-instance reset (acceptable on the dedicated head only).
  - 0.5 object store: MinIO silently drops AbortIncompleteMultipartUpload ⇒
    sweep owns MPU cleanup; tombstone-first pruning; silent public-AWS
    fallback on scope miss ⇒ egress lockdown; no cross-connection metadata
    cache ⇒ manifest file lists at scale; Linode recheck checklist recorded
    in the spike artifacts.
  - 0.6 ordering: production CNPG is C-collated (operator default) — the
    head MUST be initdb'd C (stock pgduckdb image is en_US.utf8); explicit
    NULLS + registry tiebreaker on every ORDER BY; absolute-UTC-offset time
    literals; `datcollate` guard (not `SHOW lc_collate`, removed in PG18).
  Full reports in the spike scratchpad (`spike-0.*.md`); infra remains
  runnable via the coldspike compose project for the M1 integration tests.
- **Local development and CI**: an opt-in docker-compose profile adds MinIO
  and a local analytics-head container wired to the compose CNPG, so the
  entire export→verify→drop→query-back loop (and later the M2 parity suite)
  is exercisable and CI-testable without cloud object storage. This is dev
  tooling, not an OSS enablement path — the profile is opt-in and
  undocumented in user-facing install docs, consistent with D11.
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
