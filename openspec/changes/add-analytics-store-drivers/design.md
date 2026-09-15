## Context

EventWriter consumes JetStream and owns telemetry persistence. SRQL translates
queries in a Rust NIF; Elixir executes them against the primary Repo or a
separate AnalyticsRepo. The dedicated analytics head runs pg_duckdb over
verified Parquet objects recorded in `platform.analytics_file_manifest` on the
primary. Interactive scans use concrete manifest keys.

Object-store scans are useful for historical analysis, but their per-file
request costs are unsuitable for the primary dashboard workload. The approved
revision keeps a hot Timescale copy and continuously writes the archive.

## Goals / Non-Goals

Goals:

- OSS defaults require only Timescale; hosted deployment configuration enables
  hybrid mode.
- Recent dashboards use Timescale, including its continuous aggregates.
- Older and cross-window ad-hoc queries use the complete Parquet copy.
- Configuration names the participating tables and the hot window.
- Preserve JetStream, one EventWriter owner, and the existing result contract.

Non-goals:

- Moving relational/current-state tables or installing pg_duckdb on the primary.
- Reintroducing FDW hot/cold unions, a completeness frontier, or continuous
  export of closed hypertable chunks.
- Enabling another telemetry table or changing another deployment as part of
  the current query-path repair.
- Promising interactive latency for archive queries.

## Decisions

### D1. Three explicit modes, two physical stores

| Mode | Writes | Reads | Additional backend required |
| --- | --- | --- | --- |
| `timescale` (OSS default) | Timescale | Timescale | None |
| `hybrid` (hosted default) | Timescale and Parquet | Recent: Timescale; older: pg_duckdb | Dedicated head and S3 or filesystem |
| `pg_duckdb` | Parquet | pg_duckdb | Dedicated head and S3 or filesystem |

Hybrid currently supports `timeseries_metrics` and requires an explicit table list. Unlisted tables use Timescale. The
existing empty-table-list meaning for Parquet-only mode remains compatible.
The `dualWrite` list remains useful while populating an archive with all reads
still on Timescale; hybrid automatically enables both writes for its tables.

```yaml
analyticsStore:
  driver: timescale
  tables: []
  hotWindowDays: 30
  parquetRetentionDays: ""  # hybrid: no archive expiry unless explicitly set
  dualWrite: []
```

Archive-enabled modes fail configuration validation when the head or storage
configuration is incomplete. Default Timescale starts without either. Query
failure never triggers a fallback to another store.

### D2. Continuous writes remain inside EventWriter

For a hybrid metrics table, EventWriter claims previously unseen JetStream
message receipts, inserts hot rows, and records durable archive batches in one
primary transaction. The receipt identity includes the stable source/stream,
stream sequence, and original publish timestamp; delivery attempts and consumer
sequence are excluded. Only newly inserted canonical rows enter the archive
outbox, so a repeated sample within the hot table does not create another copy.
Receipts remain independent of hot retention and published payload cleanup.

JetStream acknowledgement follows that transaction's commit. An EventWriter-owned
publisher queue then writes the durable batches. It is not a second JetStream
consumer. Archive outage queues pending payloads while hot ingestion continues;
a configurable byte budget rejects new ingest transactions before pending
payloads grow without bound. Incoming messages retain the existing JetStream
retry and terminal-delivery contract, including its finite limits. Pending payloads are never evicted by Oban job cleanup.

Each per-day archive batch has fixed membership, a schema version and checksum.
An uncertain upload retries with a new immutable candidate object. One primary
transaction selects the winning manifest object and marks the batch published;
a uniqueness constraint prevents a second visible object for the same batch.
Only then is the payload cleared. A retry of an already published batch performs
no upload. Uncommitted candidates are not query-visible.

Legacy Parquet uses `analytics/v1/<table>/date=YYYY-MM-DD/`; hybrid attempts
use `analytics/v1/<table>/_candidates/date=YYYY-MM-DD/`. The separate prefix
prevents legacy hive globs from including uncommitted candidate objects.
Hybrid reads always use manifest keys. Staging files are not query-visible. Manifest publication follows verification. Late arrivals are
partitioned by their event timestamp and remain discoverable by timestamp
bounds. The existing backend-scoped S3 secret initialization is retained.

Archive reads must not silently omit overlapping outbox work. A query snapshots
its pending batch IDs and waits a bounded interval for those batches to publish,
returning an explicit archive-not-ready error if publication cannot catch up.
New ingress does not continually extend that wait. Recent Timescale reads do not
wait on the archive.

This guarantees transport-redelivery idempotency. Republish of an already expired
sample as a brand-new source message is a different operation; historical replay
must preserve source identity or use the explicit restore path. The system does
not repair that operation by deduplicating every historical query.

### D3. Route the whole resolved query

Resolve relative time expressions and any cursor window before choosing the
SQL dialect. Let `cutoff = now - hotWindowDays`:

- A proven lower bound at or after cutoff selects Timescale.
- An older or unbounded lower bound selects pg_duckdb.
- A query spanning cutoff runs entirely on pg_duckdb, which has both sides.
- An existing entity default, such as a last-day window, is resolved normally
  before applying this rule; no new implicit truncation is introduced.

For example, with a 30-day hot window, last-hour interface charts use
Timescale, while a last-quarter aggregate runs on the archive. There is one
aggregation, ordering, rate calculation, and LIMIT per query. No merging of
partial aggregates or boundary deduplication is needed.

SRQL receives per-table mode/window configuration. It selects the dialect
before CAGG rewriting. Direct SQL readers pass their resolved bounds through
the same policy. Inventory/configuration queries always use the primary.

Hybrid pagination pins the absolute window and selected store in its signed
cursor. A continuation cannot silently move stores as time advances. A hot
cursor whose window has aged outside the hot guarantee returns an explicit
expiration error. Existing Timescale and Parquet-only cursor formats stay
compatible.

### D4. Retention and aggregates follow the hot copy

Hybrid keeps Timescale retention and CAGG refresh enabled. The rollout enables
compression for the selected metrics hypertable, leaving its recent writable
chunks uncompressed and compressing older chunks in the background. Verify
actual compressed size and query latency before treating the 30-day target as
accepted. The effective hot
retention is the greater of the existing table retention and the configured
hot read window, preserving any longer operator setting. Changing the read
window does not manufacture data previously expired; expanding an existing
window requires restoring coverage before enabling those reads.

`parquetRetentionDays` controls archive expiry in hybrid mode independently of
Timescale. Absence means no archive expiry. A finite archive window must exceed
the hot read window. Parquet-only mode retains its existing table-retention
behavior. Object deletion must succeed before its manifest entry is removed.

Returning from Parquet-only to hybrid must recreate CAGG refresh policies that
were removed. Materialized data must be refreshed over the restored interval
before aggregate queries are considered verified.

### D5. Dedicated analytics head and optional storage

pg_duckdb remains outside the primary, with its own pool, connection budget,
per-backend memory/thread limits and ephemeral spill directory. S3 and a
persistent local-filesystem backend remain supported. No S3 configuration,
secret, MinIO container, or analytics head is required by default OSS installs.
Hybrid queries on recent data do not acquire an analytics connection or list
object-store files.

The PostgreSQL-first parser restrictions still apply to archive SQL: emit
compatible `float8` and JSON operators. Keep the safe typed-parameter encoder
and disabled literal query logging for that execution path.

### D6. Rollout and recovery

1. Enable archive writes for a named table while preserving its Timescale read
   path, or restore dual writes when recovering a Parquet-only deployment.
2. Establish both copies' coverage for the promised windows. Use verified
   historical exports and a bounded, repeatable recovery through EventWriter;
   JetStream replay alone is insufficient when its retention has elapsed.
3. Restore the missing hot interval without rewriting the archive. Deduplicate
   by the table's canonical primary key, verify counts and timestamp coverage,
   and refresh the affected CAGGs.
4. Enable hybrid routing with the agreed 30-day window.
5. Verify translated dialect/target, recent rows, dashboard latency, and an
   explicitly historical archive query. Running pods or a synced deployment
   alone do not establish correctness.
6. Stop after the metrics query-path acceptance gate. Other table changes need
   their own rollout decision.

Rollback from hybrid to Timescale-only preserves the existing hot copy and
stops archive writes/reads. Previously published Parquet remains. Returning
from Parquet-only requires hot coverage restoration before recent reads switch.

## Risks / Trade-offs

- Continuous dual writes retain the cost of a bounded hot copy and add write
  amplification. Compression is independent work and remains valuable.
- Archive outages accumulate durable pending batches. At the configured buffer
  limit, new transactions fail under existing finite JetStream retry and
  terminal-delivery limits; retry and backlog monitoring remain necessary.
- Source receipts and completed batch metadata remain on the primary after
  payload cleanup. Their growth is separate from the pending-payload budget;
  safe receipt compaction and unreferenced-object cleanup are not implemented.
- Historical queries can still be slow; manifest pruning limits scope but does
  not eliminate per-file network overhead.
- CAGGs may be stale after recovery. Check actual query results after refresh.
- Hosted defaults belong to hosted deployment configuration. They must not
  alter the default OSS chart or Compose dependencies.
