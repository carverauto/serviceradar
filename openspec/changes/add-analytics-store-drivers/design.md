## Context

All high-volume telemetry still lands in CNPG hypertables via NATS
JetStream + EventWriter. SRQL is a translate-only Rust NIF; web-ng
executes the SQL with Ecto against the primary
(`elixir/web-ng/lib/serviceradar_web_ng/srql.ex`). Stats/downsample
windows ≥ 6h already route to Timescale continuous aggregates.

`add-tiered-telemetry-offload` already built, and spiked, a dedicated
pg_duckdb analytics head because pg_duckdb **cannot share a process with
TimescaleDB** (it calls `standard_planner()` and SIGSEGVs —
duckdb/pg_duckdb#845, #963, open > 12 months). That constraint stands.
What does not stand is the rest of that design: keep the hypertable as
the write path, export chunks, stitch with postgres_fdw, and invent a
frontier so `drop_chunks` cannot race the archive.

GH #477 is the product requirement: telemetry of record lives on cheap
columnar storage, queried by DuckDB, with a deployment shape that is
stateless at the compute layer (object storage or a local data dir holds
the files; the head spills to `emptyDir`).

Two clusters will not share a backend:

| | block (Longhorn / none) | object storage |
|---|---|---|
| carverauto `demo` | Longhorn is the CNPG volume; it is the thing we are trying to get telemetry off | bucket already exists for backups |
| farm01 | no object storage provisioned | n/a |
| OSS compose | local Docker volume | optional MinIO profile |

## Goals / Non-Goals

- Goals:
  - One analytics-store interface. EventWriter, SRQL, and in-process
    readers (capacity, anomaly silence, retrohunt) go through it.
  - Operators choose `timescale` or `pg_duckdb` in Helm / Compose, and
    for pg_duckdb choose `s3` or `filesystem` for the Parquet files.
  - When pg_duckdb owns a table, CNPG is not in that table's write path.
  - DuckDB runtime is pg_duckdb on the existing analytics image. No new
    Elixir NIF, no experimental Quack protocol, no dataframe API in front
    of SRQL.
  - Default driver `timescale` — zero behavior change until a deployment
    flips the value.
  - Spill is `emptyDir` + explicit `memory_limit`, matching GH #477.
- Non-Goals:
  - Moving relational / current-state tables (~49 GB) off CNPG.
  - Embedding pg_duckdb in the tenant primary.
  - Adopting duckdbex, Dux, QuackDB, or quack_lake.
  - Delta / Iceberg / DuckLake in v1 (single writer, append-only,
    hive partitions).
  - Dual-running Timescale CAGGs *and* Parquet rollups for the same
    table once that table has flipped.
  - Cross-tenant shared analytics heads.
  - Replacing barman / CNPG backups.

## Decisions

### D1. pg_duckdb is the DuckDB runtime, not an Elixir library

SRQL's contract is SQL in, rows out. web-ng already has a Postgres
client. A second CNPG-shaped instance that speaks Postgres and runs
DuckDB plans is the smallest new surface.

Rejected:

- **duckdbex** — embeds C++ DuckDB as a NIF next to the SRQL NIF.
  Write + query would work, but we then own memory/spill/extension
  loading inside the BEAM, lose Ecto pooling, and still need an S3
  story. The analytics image already solved those as Postgres GUCs.
- **Dux** — dataframe verbs compiling to SQL. SRQL already compiled to
  SQL. Dux is also explicitly not production-ready.
- **QuackDB** — DBConnection + Ecto over DuckDB's experimental Quack
  protocol (beta, breaking changes expected through DuckDB 2.0).
- **duckdb-rs inside the SRQL NIF** — puts scan memory in the web-ng
  process. A large aggregation OOMs the UI. The head exists so that
  does not happen.

The analytics head remains a small single-instance CNPG cluster from
`serviceradar-cnpg-analytics`. That image is the same CloudNativePG
PostgreSQL 18 base as the primary (UID 26, barman tools) plus a
pg_duckdb extension layer lifted from the digest-pinned official
pgduckdb/pgduckdb image. It does **not** republish that image as-is
(UID 999, no CNPG instance-manager layout) and it does **not** load
Timescale/AGE/PostGIS. Its PGDATA is tiny catalog state, not the
telemetry. Data of record is Parquet.

### D2. Two drivers at the store, two backends under Parquet

```
AnalyticsStore (behaviour)
├── TimescaleDriver      → primary CNPG hypertables
└── PgDuckDBDriver       → analytics head
        ├── S3Storage        (httpfs / DuckDB S3 secret)
        └── FilesystemStorage (allowed LocalFileSystem on a data dir)
```

Helm:

```yaml
analyticsStore:
  driver: timescale          # or pg_duckdb
  tables: []                 # empty = all registry tables when driver=pg_duckdb
  pgDuckdb:
    storage: s3              # or filesystem
    s3:
      bucket: ""
      endpoint: ""
      region: ""
      secretName: ""
    filesystem:
      path: /var/lib/serviceradar/analytics
      hostPath: ""           # farm01 local NVMe
      pvc:
        enabled: false
        storageClass: ""
        size: 200Gi
    memoryLimitMb: 1536
    threads: 2
    spill:
      emptyDir: true
      sizeLimit: 50Gi
```

`driver: timescale` renders no analytics head. `driver: pg_duckdb`
requires a storage backend and fails closed (core refuses to start)
rather than silently writing hypertables.

A later table-level map (`tables: [timeseries_metrics, ocsf_network_activity]`)
is how demo cuts over largest-first without flipping logs/traces on day
one. Unlisted registry tables stay on Timescale.

### D3. Writes go to the selected driver. No hot∪cold stitch.

When a table is on `pg_duckdb`, EventWriter's bulk insert for that table
becomes `COPY ... TO '<backend>/.../date=YYYY-MM-DD/<batch>.parquet'`
(or `INSERT INTO ... SELECT ...` into a DuckDB view over that layout)
executed on the analytics head. The primary hypertable is not in the
path.

This is the simplification versus `add-tiered-telemetry-offload`:

| | offload-from-CNPG (superseded) | this change |
|---|---|---|
| Write | EventWriter → hypertable | EventWriter → Parquet via head |
| Read | SRQL routes by window to primary or stitched view | SRQL routes by entity to the entity's driver |
| Retention | export-gated `drop_chunks` + frontier | Parquet lifecycle job on the prefix; Timescale retention only for tables still on `timescale` |
| Failure mode | head down ⇒ export stalls, hypertables grow | head down ⇒ EventWriter nacks, JetStream replays (same as today's CNPG outage) |

Late-arriving rows are new Parquet files in the right `date=` partition.
There is no closed-chunk mutation problem because there is no chunk.

v1 layout (reused from the registry):

`{backend}/analytics/v1/<table>/date=YYYY-MM-DD/<writer>-<batch>.parquet`

zstd, rows sorted by (time, tiebreakers). Readers glob `date=*`. A
small `platform.analytics_file_manifest` on the **primary** (not the
head — the head is disposable) records verified files so a truncated
COPY cannot become query-visible. Staging → verify → publish, which
spike 0.3 of the superseded change already proved is required.

The head is rebuilt from the manifest + storage backend on startup.
That is what "stateless compute" means here.

### D4. SRQL dialect, not a second language

`Native.translate` grows a dialect argument (`postgres` default,
`duckdb` when the entity's driver is pg_duckdb). Entity → driver is
runtime config supplied by the Elixir caller (the NIF stays stateless).

DuckDB dialect:

- No Timescale CAGG rewrite. ≥6h stats/downsample become DuckDB
  `date_trunc` / `time_bucket` over the Parquet view. Document that
  partial-bucket numbers can differ from CAGGs; golden tests bound it.
- `jsonb` operators remap to DuckDB JSON (registry already exported
  jsonb as text). Fail closed on untranslatable constructs.
- No `DISTINCT ON`; emit `QUALIFY row_number()` where the postgres
  dialect used it.
- Partition predicates from the resolved time window, unique
  tiebreaker, explicit NULLS (spike 0.6).

web-ng `execute_translation` picks `Repo` or `AnalyticsRepo` from the
translation's driver tag. Background jobs that today issue SRQL against
metric entities (capacity forecasting, seasonal disposition) must pass
through the same picker — they cannot assume the primary has the rows.

Device / inventory / config entities always stay `postgres` / primary.

### D5. JetStream doctrine does not change

`observability-signals` "Metric Ingestion via JetStream" still holds:
collectors never write the store; EventWriter is the single writer after
the stream. The MODIFIED wording is "persisted by EventWriter into the
configured analytics store", not "into the database". Dual-write is
allowed only as a measured cutover window for a named table, with a
feature flag, and is removed once SRQL parity on that table passes.

### D6. What is reused from `add-tiered-telemetry-offload`

Keep:

- `serviceradar-cnpg-analytics` image and boot-smoke gate.
- Helm analytics-head Cluster CRD, role gate, `duckdb.max_memory` /
  `threads` / extension lockdown.
- `ServiceRadar.ColdTier.Registry` as the table inventory (column
  lists, casts, partition layout, SRQL entity map). Rename in a
  follow-up if the "cold" vocabulary becomes a lie; not blocking.
- Proven `COPY ... TO parquet` through the head, staging→verify→publish.
- Network policy shape, adjusted for filesystem mode (no object-store
  egress; LocalFileSystem enabled only on the data dir).

Drop:

- Completeness frontier `F` and stitching seam `B`.
- postgres_fdw / `PGDUCKDB_POSTGRES_SCAN` hot branch.
- Export-gated retention / `RetentionFence` as the drop authority for
  flipped tables.
- SRQL "cold vs hot window" routing (`rust/srql/src/query/cold.rs`).
- Pressure-relief against a growing primary (the primary is no longer
  holding the flipped table).

### D7. Rollup replacement when a table flips

Timescale CAGGs for a flipped table stop being the query path (there is
nothing to refresh). DuckDB aggregation over hive-partitioned Parquet is
the v1 replacement; it is the reason we are moving. If a dashboard KPI
is too slow as an on-read aggregate, a follow-up writes a rollup Parquet
prefix. Do not keep a shadow hypertable just to feed CAGGs.

### D8. Cutover for an existing deployment (demo)

1. GH #478 compression is live (shrinks the problem during the work).
2. Stand up the analytics head with `storage: s3` on `demo`.
3. One-shot backfill: the existing chunk exporter is the migration tool
   — copy historical hypertables into the Parquet layout, verify, then
   stop using it as a continuous pipeline.
4. Dual-write the candidate table (flagged) and run the SRQL parity
   suite against both drivers.
5. Flip `analyticsStore.tables` to include the table; EventWriter stops
   writing the hypertable; retention drops the hot copy on the normal
   schedule.
6. Repeat for `timeseries_metrics`, then `ocsf_network_activity`, then
   the rest of the registry.

farm01 stays `driver: timescale` until it has a local NVMe path or a
bucket. The filesystem backend exists so that flip does not depend on
object storage.

## Risks / Trade-offs

- **Analytics head down = that table's ingest blocks.** Same as CNPG
  down today; JetStream is the buffer. Mitigation: head is small and
  disposable, replay is the recovery.
- **DuckDB SQL drift from Diesel/Postgres.** Mitigation: fail closed;
  golden suite on the compose profile; dialect tests in `rust/srql`.
- **Longhorn as a Parquet PVC.** Sequential writes may still be poor;
  the filesystem backend is aimed at hostPath local NVMe, not at
  putting Parquet on the same Longhorn class we are leaving. S3 is the
  demo path.
- **Object-store request/egress pricing** (open in GH #477). Do not put
  a retention number on a pricing page until transfer accounting is
  confirmed. The driver still ships.
- **Partial-file reads from a glob.** Staging→verify→publish plus
  readers globbing only published keys (already proven) stays
  mandatory.

## Migration Plan

- Schema: manifest table on the primary; no change to hypertable DDL
  until a table flips, at which point retention continues to drop the
  abandoned hot copy.
- Helm defaults stay `driver: timescale`. Demo values flip per table
  after step 5 above.
- Rollback for a flipped table: turn the table back to `timescale`,
  replay JetStream from the flip timestamp if the hypertable was
  dropped, or wait for the next retention window if it was not. Parquet
  already written stays; it is not deleted on rollback.

## Open Questions

- Exact first table on `demo` (`timeseries_metrics` vs
  `ocsf_network_activity`). Recommendation: `timeseries_metrics` (7-day
  window, smaller catch-up, SRQL surface is well tested). Not blocking
  the spec.
- Whether farm01 ever wants `filesystem` or stays Timescale. The driver
  exists either way.
