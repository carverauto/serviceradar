---
title: Analytics Store
---

# Analytics Store

High-volume telemetry (`timeseries_metrics`, `ocsf_network_activity`, logs,
traces, and the rest of the cold-schema registry) can live in one of two
stores:

- **timescale** (default) -- CNPG hypertables and Timescale continuous
  aggregates. This is OSS, Compose, and farm01 today.
- **pg_duckdb** -- hive-partitioned Parquet on object storage or a local
  filesystem, queried by a dedicated analytics-head Postgres that loads
  `pg_duckdb`. Never installed next to Timescale on the primary (that pairing
  SIGSEGVs).

The driver is per deployment, and per table inside a deployment. A site that
never sets a bucket or a head keeps today's EventWriter and SRQL path.

Metrics still go through NATS JetStream first. EventWriter is the only writer
into either store.

## Helm values (`analyticsStore`)

Defaults are in `helm/serviceradar/values.yaml`. Chart default is
`driver: timescale` and `headEnabled: false` -- no analytics-head Cluster.

| Key | Default | Meaning |
| --- | --- | --- |
| `driver` | `timescale` | `timescale` or `pg_duckdb`. Incomplete `pg_duckdb` refuses to start core (no silent hypertable fallback). |
| `headEnabled` | `false` | Render the head Cluster without flipping any table (idle soak). |
| `tables` | `[]` | Tables on `pg_duckdb`. Empty + `driver: pg_duckdb` flips every registry table. Name tables explicitly on a live cutover. |
| `dualWrite` | `[]` | EventWriter writes Timescale then Parquet. Requires a complete head+storage backend. Parquet failure nacks JetStream. |
| `pgDuckdb.storage` | `s3` | `s3` or `filesystem`. |
| `pgDuckdb.s3.secretName` | `""` | Kubernetes Secret with `access_key_id` / `secret_access_key`. ServiceRadar talking to itself, not a device credential. |
| `pgDuckdb.s3.bucket` | `""` | Dedicated analytics bucket. Do not reuse the CNPG barman backup bucket. |
| `pgDuckdb.s3.endpoint` / `region` / `urlStyle` / `useSSL` | path-style, TLS on | S3-compatible endpoint. |
| `pgDuckdb.s3.egressCidrs` | `[]` | NetworkPolicy cannot match FQDNs. Empty means no object-store egress rule. |
| `pgDuckdb.filesystem.path` | `/var/lib/serviceradar/analytics` | Directory DuckDB COPY uses when `storage: filesystem`. |
| `pgDuckdb.memoryLimitMb` / `threads` | `1536` / `2` | DuckDB `max_memory` and thread count. |
| `pgDuckdb.spill.emptyDir` / `sizeLimit` | `true` / `50Gi` | Scratch-data emptyDir at `/run/pg_duckdb`. Do not put Parquet here. |
| `pgDuckdb.poolSize` / `overheadMb` | `4` / `1536` | Query pool. Pod memory request is `poolSize * memoryLimitMb + overheadMb`. |
| `pgDuckdb.maxConnections` | `60` | PostgreSQL connection slots on the head. Budget for every core and web replica, rolling-update overlap, writers, and reserved/admin connections. |
| `affinity` | unset | Optional nodeSelector / tolerations for the head (dedicated CNPG nodes). |

S3 mode sets `duckdb.disabled_filesystems=LocalFileSystem`. Filesystem mode
omits that so COPY can write the data dir.

Fail-closed boot: `driver: pg_duckdb` without a bucket+credentials (S3) or
path (filesystem), or without a head, is an error. Core does not start and
EventWriter does not insert those tables into hypertables.

## Query execution

SRQL resolves its time window before selecting published files from
`platform.analytics_file_manifest` on the primary. The analytics query receives
concrete Parquet keys whose timestamp bounds overlap the requested UTC window;
interactive queries do not plan a `date=*` object-store scan. Files without
recorded bounds remain eligible. An empty manifest selection returns no rows, and a
manifest lookup failure returns an error. Backfills must be verified and recorded
in the manifest before readers can see them. EventWriter uses UUID batch keys
and records actual timestamp extrema, so separate replicas cannot overwrite
each other's objects and late-arriving samples remain visible.

The pg_duckdb connection uses PostgreSQL-compatible types and safely encoded
typed literals for analytics parameters. This avoids the extension's unbound
parameter planning errors. Analytics query logging is disabled because those
literals include filter values; the Timescale path retains parameter binding.

S3 reader and writer sessions select the bundled curl HTTP client after DuckDB
initialization. This avoids long connection attempts when an endpoint advertises
IPv6 addresses that the head cannot reach. S3 secrets remain scoped to each
backend and are retained across other sessions' writes.

## Docker Compose

`docker compose up -d` does not start an analytics head or MinIO.

```bash
# S3-compatible MinIO + head
docker compose --profile analytics up -d

# Local directory (no MinIO)
docker compose --profile analytics-fs up -d
```

Copy `docker/compose/analytics.env.example` to `analytics.env` and point
`core-elx` / `web-ng` at it from a compose override when you want
`driver: pg_duckdb`. Leave the env file off to soak the head without flipping
writes.

## Cutover and rollback

Order for an existing deployment (demo used this):

1. Timescale compression on the primary, if you have it. Shrinks the
   hypertable while you work.
2. Stand up the analytics head (`headEnabled: true` or `driver: pg_duckdb`)
   with a complete S3 or filesystem backend. Dedicated bucket, dedicated
   Secret. Confirm spill emptyDir and `duckdb.max_memory`.
3. One-shot backfill of closed UTC days into
   `analytics/v1/<table>/date=YYYY-MM-DD/`. Row counts must match the
   hypertable per day. Leave the incomplete current day for dual-write.
4. Dual-write the candidate table (`analyticsStore.dualWrite` on demo is
   `timeseries_metrics`). SRQL parity on a closed window (listing + a stats
   query of 6h or more). Dual-write still feeds Timescale CAGGs. The
   incomplete current UTC day is a half-open range copy `[00:00, dual-write
   start)` plus EventWriter files after that; do not re-COPY the whole day
   once dual-write has published into `date=YYYY-MM-DD/`.
5. Flip `analyticsStore.tables` (and `driver: pg_duckdb`). EventWriter stops
   inserting the hypertable. `pg_stat_user_tables.n_tup_ins` for that table
   must stop climbing; JetStream consumer lag must not grow. SRQL uses the
   duckdb dialect (no `*_hourly` CAGGs). Timescale retention ages the
   abandoned hot copy; Parquet prune uses the same
   `SERVICERADAR_*_RETENTION_DAYS` window.
   Verify ICMP and interface charts on the device pages within their request
   budgets, with no Postgrex errors or pool timeouts, before moving another table.
6. Repeat per table: `timeseries_metrics` first, then
   `ocsf_network_activity`, then the rest of the registry.

Rollback for a flipped table:

1. Set `driver: timescale` (or remove the table from `tables`) and roll core
   and web-ng.
2. If the hypertable still has rows (retention has not dropped them), writes
   resume there. Parquet already published stays; it is not deleted.
3. If `drop_chunks` already removed the hot copy, replay JetStream from the
   flip timestamp. EventWriter is the single writer after the stream;
   collectors must not insert the store themselves.
4. CAGG refresh policies are removed on flip and not re-armed automatically.
   Re-install them from the original migration if you need the Timescale
   stats path again.

cpu / memory / disk / process hourly CAGGs stay on Timescale until those
hypertables are in the registry and flipped.

## farm01 and other Timescale-only sites

farm01 stays `analyticsStore.driver: timescale` in this change. Do not flip
it until it has either a dedicated object-store bucket or local NVMe.

Filesystem recipe when you are ready (not Longhorn):

```yaml
analyticsStore:
  driver: timescale          # keep until the head is healthy
  headEnabled: true
  pgDuckdb:
    storage: filesystem
    filesystem:
      path: /var/lib/postgresql/data/analytics
    storageClass: local-path   # hostPath-backed or local NVMe class
    spill:
      emptyDir: true
      sizeLimit: 50Gi
  affinity:
    nodeSelector:
      # pin the head to the node that holds that PV
```

CNPG does not expose an extra hostPath volume on the analytics Cluster in
this chart. Use a local StorageClass (OpenEBS local PV, k3s local-path, or
equivalent) sized for Parquet, and pin the pod. Sequential writes on
Longhorn are a poor fit; that is why farm01 waits.

Compose analogue: `--profile analytics-fs`.

## Object-store pricing

Request and egress pricing for analytics Parquet is still unconfirmed.
Do not put a retention-day figure on a pricing page from this feature.
Retention windows in Helm (`SERVICERADAR_*_RETENTION_DAYS`) are operational
delete policies, not a commercial entitlement.
