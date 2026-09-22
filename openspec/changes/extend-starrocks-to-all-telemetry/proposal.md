# Change: Make StarRocks the system of record for all telemetry, and retire it from CNPG

## Why

`add-starrocks-telemetry-analytics` made StarRocks an optional warehouse for four datasets
(flows, scalar metrics, logs, events) and left CNPG receiving every write. That was the right
first step and it is where the cost still is: telemetry is stored twice, the expensive copy is
the one on PostgreSQL volumes, and everything the OTel pipeline produces (metric points, traces),
plus MTR, BMP, service status and the sysmon tables, is not in the warehouse at all.

Shared-data StarRocks keeps table data in object storage, so retention costs bucket space rather
than database volume, and the now-partitioned tables expire by dropping a day. Operators want
telemetry kept for a long time for little money, and CNPG reduced to what has to be a
transactional database.

The first cutover also showed what the existing proposal under-specified. Cutting the
`metrics` dataset over looked correct on the queries that were checked and was wrong on the ones
that were not: `agg:rate` was compiled as a sum of cumulative counters, so an interface charted
rates orders of magnitude above its line speed; a series could not be split by a tag, so the
per-core CPU chart failed; `sort:desc limit:N` kept the oldest buckets instead of the newest.
An inventory of every chart
query then found the same class of gap waiting in `logs` and `events`: `rollup_stats:` is
silently ignored by the StarRocks dialect and returns raw rows, which the severity cards read as
zeros with no error, and their filter vocabulary (`severity:`, `log_level:`, `event_type:`,
`device_id:`) is refused. A clause that is ignored is worse than one that is refused.

Separately, the first online partition rebuild showed that a day is too large a unit of
maintenance work: on a modest warehouse, day-sized statements exceed a compute node's memory
limit and the node is OOM-killed (issue #4525). The same issue records that the migration lock
wait is cancelled by Postgres `statement_timeout`.

## What Changes

- **Parity before cutover, as a gate that can fail.** A dataset is cut over only after every
  query shape the product sends for it has been run through both dialects against the same data
  and the results compared. The inventory of query shapes is derived from the code, not from
  memory, and is re-derived when it changes.
- **The StarRocks dialect refuses what it cannot answer.** Any clause it does not implement
  (`rollup_stats:`, `other:true`, an unknown field) is an error, never dropped. **BREAKING** for
  any caller currently relying on a silently ignored clause; there should be none that are
  correct.
- **Bring `logs` and `events` reads to parity and cut them over**: severity and
  anomaly-finding rollups as warehouse aggregates, the CNPG filter vocabulary, top-N with an
  "Other" tail, and the non-SRQL dashboard readers that still query CNPG directly.
- **Extend the warehouse to the rest of the append-only telemetry**: OTel metric points and
  metric definitions, OTel traces/spans and their RED and summary rollups, MTR traces and hops,
  BMP routing events, service status history, and the sysmon CPU/memory/disk/process tables.
  Each gets a warehouse table, an EventWriter destination behind the existing JetStream-first
  single-owner path, SRQL dataset routing, and rollups as async materialized views.
- **Retire telemetry from CNPG, one dataset at a time, as an explicit one-way step.** After a
  dataset's reads are cut over, its non-UI consumers are migrated and it has run clean for a
  declared soak period, an operator action stops CNPG writes for it. After a second, shorter
  retirement hold with writes off and no reader errors, a separate action drops its hypertable
  and continuous aggregates. Nothing retires automatically.
- **State what stays in CNPG**: current state and anything updated in place under transactional
  guarantees -- inventory and identity, credentials, RBAC and configuration, alert and rule
  state, jobs, and the enrichment caches the warehouse joins to through the read-only catalog.
- **Bounded maintenance.** Warehouse maintenance that moves data (the partition rebuild, future
  backfills) works in units sized to the smallest supported compute node and backs off on
  memory pressure instead of retrying into it.
- **The migration lock wait is not cancelled by a timeout.** The transaction that holds the
  warehouse migration lock clears Postgres `statement_timeout` and `lock_timeout` for itself, so
  a replica waiting behind a long rebuild keeps waiting instead of failing (issue #4525).
- **Decide log search honestly.** Free-text search over long log retention is accepted only on
  measured evidence of which index types the deployed StarRocks profile supports.

## Impact

- Affected specs: `telemetry-analytics` and `srql` (both introduced by the still-pending
  `add-starrocks-telemetry-analytics`; this change only ADDS requirements to them and repeats
  none of that change's requirement blocks, so archiving either one cannot overwrite the other).
- Affected code: `rust/srql/src/query/starrocks.rs` and the dataset routing in
  `ServiceRadar.Analytics.StarRocks.Readers`; EventWriter destinations and
  `priv/starrocks/*.sql`; direct CNPG readers under `elixir/web-ng/.../dashboard_live/data/`,
  `log_live`, `device_live/flow_data.ex`; non-UI consumers of telemetry (stateful alert engine,
  log promotion, capacity forecasts, anomaly backfill, topology sparklines); Helm/Compose values
  for dataset lists and retention; operator docs.
- Depends on `add-starrocks-telemetry-analytics` task 5.4 (migrate non-UI scalar-metric
  consumers). Cutting READS over does not need it, because CNPG still receives every write.
  Stopping CNPG WRITES does.
- Supersedes nothing. `add-tiered-telemetry-offload` addresses cold storage for CNPG-resident
  telemetry; once a dataset is retired from CNPG it no longer applies to that dataset.
- Risk: write retirement removes the rollback path for that dataset. That is the purpose of the
  soak that precedes it and of making it a deliberate operator action.
