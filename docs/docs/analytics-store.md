---
title: Analytics Store
---

# Analytics Store

ServiceRadar defaults to **Timescale only**. OSS installations do not need
object storage, archive credentials, MinIO, or an analytics head.

Operators can enable **hybrid** storage for `timeseries_metrics`. EventWriter
then continuously writes to both Timescale and Parquet. Recent dashboards use
Timescale; historical queries use a dedicated pg_duckdb head. Hosted deployments
use the hybrid tenant template without changing the OSS defaults.

| Mode | Writes | Query path |
| --- | --- | --- |
| `timescale` (default) | Timescale | Timescale |
| `hybrid` (opt-in) | Timescale and Parquet | Entirely within the hot window: Timescale; otherwise: pg_duckdb |
| `pg_duckdb` (opt-in) | Parquet | pg_duckdb |

All telemetry still passes through NATS JetStream first. EventWriter remains
the single persistence owner. Collectors do not connect to either store.

## Fast recent reads

Hybrid's hot window defaults to **30 days** and is configurable. For example:

- Last-hour ICMP and interface charts use Timescale, with no archive scan.
- A query entirely within the last 30 days uses Timescale and eligible
  continuous aggregates.
- A query for the last 90 days runs entirely on pg_duckdb. The Parquet copy
  includes recent data, so the query needs no cross-store aggregation or merge.

Relative times resolve before routing. Existing entity defaults still apply.
A genuinely unbounded query uses the archive. Query failures return errors;
they do not silently retry against another store. Hybrid pagination pins both
the absolute window and store; an expired hot cursor must be restarted.

The metrics hypertable uses a schema-managed compression policy after two days.
The newest chunks remain writable; older chunks compress in the background.
Compression does not change the query API. Verify actual size and query latency
on the deployment before treating the 30-day storage target as accepted.

## Metric history windows

Device sysmon and interface history offer 1h, 6h, 24h, 7d, 30d, and 90d
windows. Longer windows use coarser buckets so chart point limits cover the
entire period. Custom accepts UTC start and end dates and opens a prefilled
SRQL query with the selected device, interface, and metric filters.

The NetFlow page offers the same range controls. Its storage remains Timescale
until that dataset is explicitly enabled; selecting a longer range does not
create archive coverage or recover expired data. Native flow queries currently
allow at most 395 days per request.

Longer NetFlow windows use the existing hourly and daily Timescale aggregates.
The migration repairs missing refresh schedules and seeds up to 29 days from
retained smaller aggregates, preserving operator schedules and older parent
history. Startup seeding skips sources with real-time aggregation enabled so it
cannot scan raw telemetry during deployment. It cannot reconstruct data that
has already expired. Summary cards
report aggregate totals for the selected window; unavailable aggregates show an
error instead of substituting the current page's record count.

Stacked port and source-IP charts use hourly dimension aggregates for supported
byte and packet sums. Partial boundary hours and unmaterialized history come
from the raw hypertable. Filters that those aggregates cannot represent keep
the raw query path.

Changing a window clears the previous chart while the new results load. Device
sysmon requests share a 15-second budget across their queries; a failed request
stops loading and can be retried by selecting a window again.

To verify archive reads, choose a bounded range older than the configured hot
window **that actually contains published archive data**. Recent dashboard
queries test Timescale, and an empty historical result alone does not prove
archive execution. Verify the translated backend, concrete manifest files,
returned rows, and elapsed query time. Avoid unbounded maintenance-view scans.

## Helm configuration

The chart default remains:

```yaml
analyticsStore:
  driver: timescale
  headEnabled: false
  tables: []
  dualWrite: []
```

To enable hybrid, provide a complete backend and name its tables:

```yaml
analyticsStore:
  driver: hybrid
  tables: [timeseries_metrics]
  hotWindowDays: 30
  parquetRetentionDays: ""  # no archive expiry unless explicitly configured
  pgDuckdb:
    storage: s3
    s3:
      bucket: example-telemetry-archive
      endpoint: objects.example.com
      region: example-region
      secretName: example-archive-credentials
```

These example names are synthetic. Supply the endpoint, bucket, and credentials
for your deployment. The Secret contains `access_key_id` and
`secret_access_key`; it is an internal storage credential, not a monitored-device
credential. Use a dedicated analytics bucket, separate from CNPG barman backups.

| Key | Default | Meaning |
| --- | --- | --- |
| `driver` | `timescale` | Explicit storage mode. Hybrid and pg_duckdb fail validation without a complete backend. |
| `tables` | `[]` | Hybrid requires named tables. Unlisted tables stay Timescale. In pg_duckdb mode only, an empty list retains the existing all-registry-table behavior. |
| `hotWindowDays` | `30` | Hybrid read cutoff. Hot retention covers at least this window and preserves longer table settings. |
| `parquetRetentionDays` | `""` | Hybrid archive expiry, measured from event time. Blank retains history. A finite value must exceed the hot window. |
| `archiveBufferMaxBytes` | `268435456` | Maximum durable unpublished payload bytes. At the limit, new ingest fails under the configured JetStream retry limits; committed pending work is never evicted. |
| `dualWrite` | `[]` | Optional named archive writes with Timescale reads during migration. Hybrid already writes both stores. |
| `headEnabled` | `false` | Provision the head for preparation without changing storage mode. |
| `pgDuckdb.storage` | `s3` | `s3` or `filesystem`. |
| `pgDuckdb.filesystem.path` | `/var/lib/serviceradar/analytics` | Persistent Parquet directory for filesystem mode. |
| `pgDuckdb.poolSize` | `4` | Analytics connections per application replica. |
| `pgDuckdb.maxConnections` | `60` | Head connection budget, including all replicas, writers, rollout overlap, and administrative reserves. |
| `pgDuckdb.memoryLimitMb` / `threads` | `1536` / `2` | Per-backend DuckDB limits. |
| `pgDuckdb.spill.emptyDir` / `sizeLimit` | `true` / `50Gi` | Ephemeral scratch space, separate from persistent Parquet. |
| `pgDuckdb.s3.egressCidrs` | `[]` | Object-store egress for environments using NetworkPolicies. |

The head remains separate from the Timescale primary. Its extension, connection
limits and scratch storage do not change the primary's extension set. No
pg_duckdb extension is installed on the primary.

Filesystem mode uses a persistent data volume, such as local NVMe with a local
StorageClass and appropriate node placement. Parquet must not live in the spill
`emptyDir`. Default Timescale installations can remain Timescale indefinitely.

## Archive queries and retries

Readers select concrete published file keys from
`platform.analytics_file_manifest` on the primary using the query's timestamp
bounds. Interactive reads do not plan a `date=*` scan. A manifest lookup failure
returns an error; an empty manifest selection returns no rows. Only verified,
published objects are visible.

Metric compaction sorts rows by device, metric name, and timestamp so Parquet
row-group statistics can skip unrelated devices. Scheduled compaction combines
at most 256 files and 500,000 rows from one day. For an existing unsorted daily
file, operators can call
`ServiceRadar.AnalyticsStore.Compactor.rewrite_file("timeseries_metrics", manifest_id)`
from a release RPC. This explicit operation accepts one published file of at
most 10 million rows, with known bounds within one UTC day and at least ten
minutes since both its last sample and publication. It requires hybrid mode
and an idle analytics head; already rewritten files are rejected.

Both operations verify row count, timestamp bounds, and two order-independent
row hashes before atomically replacing the manifest entry. Source objects stay
available for at least 24 hours to protect readers that already selected them.
Rewriting preserves duplicate rows and does not recover missing history. Measure
one file and the corresponding query before scheduling further legacy rewrites.

EventWriter commits hot rows, durable source receipts, and fixed archive batches
in one primary transaction, then acknowledges JetStream. Its archive publisher
processes those batches asynchronously. A retry reuses the recorded membership;
regrouped messages cannot create another query-visible copy. Publication selects
one immutable object per batch atomically with its manifest entry. Hybrid objects
live under `analytics/v1/<table>/_candidates/date=YYYY-MM-DD/` and become visible
only through that manifest. Legacy hive maintenance views are not a hybrid read
interface. Failed uploads may leave unreferenced objects; automatic orphan
cleanup is not implemented.

During an archive outage, pending payloads remain on the primary. The configured
buffer limit rejects new ingest transactions. Those messages remain subject to
JetStream retention, retry, and terminal-delivery limits; size both buffers for
the tolerated outage. Oban job cleanup cannot
remove unpublished payloads. Monitor archive lag and retries alongside stream
lag. Historical queries wait briefly for overlapping pending batches and return
an explicit error if the archive is not ready; they do not silently omit that
work. Recent Timescale reads do not wait. The buffer limit covers pending
payloads, not total database disk usage. Source receipts and completed batch
metadata currently remain on the primary to preserve retry identity after hot
retention; include their growth in capacity monitoring.

Transport redelivery retains its original source identity. Historical recovery
uses the restore path; republishing expired samples under new source identities
is not an idempotent replay operation.

pg_duckdb parses SQL through PostgreSQL first. The archive query path retains
compatible types and JSON expressions, typed literal encoding, and backend-local
S3 secrets. Literal query logging is disabled on that path. Timescale uses normal
bound parameters.

Hybrid archive expiry first removes expired files from the published manifest in
a short transaction. Their objects remain for at least 24 hours so readers that
already captured the old keys can finish. S3 cleanup verifies absence after
deletion and retains the manifest records and batch provenance. Filesystem
cleanup requires access to the head's storage and is not performed by this job.
Compaction uses the same retirement grace period.

After a table has used durable hybrid publication, switching to `pg_duckdb` does
not enable legacy delete-first pruning for that table. It returns
`hybrid_archive_retention_required`; use hybrid mode with an explicit
`parquetRetentionDays` to expire that archive while preserving its retry history.

## Enablement and recovery

1. Provision the dedicated head and persistent archive backend. Keep default
   reads on Timescale while preparing the archive.
2. Enable named `dualWrite` and verify fresh batches in both stores. Backfill
   historical data through the verified manifest path, with a precise boundary
   that avoids overlapping an existing export.
3. Confirm hot coverage before enabling time routing. A previous Parquet-only
   interval must be restored. JetStream replay works only while those messages
   are still retained; older recovery must use verified archive files.
4. Use `ServiceRadar.EventWriter.AnalyticsRestore.run/3` for a bounded
   `timeseries_metrics` hot-copy recovery. It reads small half-open windows,
   inserts with primary-key conflict handling, verifies the restored keys, and
   reports the last completed window. It does not publish another archive copy.
   A failed or interrupted interval can be retried.
5. Apply the compression migration and reconcile retention and CAGG policies.
   Refresh the recovered interval in the affected aggregates. Confirm compression
   progress through Timescale job and chunk statistics.
6. Set `driver: hybrid`, keep the selected table list explicit, and verify
   actual recent rows, translated query targets, ICMP sparklines, interface
   charts, and a historical query. Use the application's request budget as the
   latency gate, not pod readiness alone.

Increasing retention cannot recover data already deleted from both stores.
Restore any available archive coverage and let the longer hot window accumulate.
Do not claim historical completeness that has not been verified.

To return from hybrid to Timescale-only, drain pending archive batches, then
select `timescale` and clear named `dualWrite`. The hot copy remains; published Parquet is not deleted by that
configuration change. Rolling back a compression policy does not automatically
decompress existing chunks; schedule that separately if needed.

## Docker Compose

Default `docker compose up -d` requires no analytics profile. Optional profiles
provide the backend:

```bash
docker compose --profile analytics up -d     # MinIO and pg_duckdb
docker compose --profile analytics-fs up -d  # persistent filesystem and pg_duckdb
```

Use `docker/compose/analytics.env.example` and its documented override to pass
backend configuration to core-elx and web-ng and explicitly select hybrid.
Starting a backend profile alone does not change EventWriter or query routing.

Archive retention settings are operational deletion policies. Storage request
and egress costs depend on the chosen provider and workload.
