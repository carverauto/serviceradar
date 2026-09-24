# Design: StarRocks as the telemetry system of record

## Context

Where things stand, in a deployment that has moved flows over: flows are read only from the
warehouse; metrics readers are being moved; logs and events are dual-written and read from CNPG;
nothing else is in the warehouse. All four warehouse tables are partitioned by day with
per-dataset retention, and the three hourly rollups are day-partitioned async materialized
views. CNPG still receives every telemetry write: that dual-write is what this revision removes
(Decision 1).

Where the money is: flows and scalar metrics dominate CNPG telemetry storage by roughly two
orders of magnitude over every other dataset, which is why they are retired first.

## Goals / Non-Goals

- Goals: with StarRocks enabled, every append-only telemetry dataset stored in and served from
  the warehouse only; no chart that silently shows different numbers after a reader moves; CNPG reduced to
  transactional state; maintenance safe on a modest warehouse.
- Non-Goals: moving inventory, identity, credentials, configuration, alert state or jobs;
  replacing the JetStream-first single-owner write path; making StarRocks mandatory (an
  installation without it keeps CNPG telemetry exactly as today).

## Decisions

### 1. An enabled warehouse is the only telemetry store

Enabling StarRocks is the whole switch. EventWriter writes every append-only telemetry dataset to
the warehouse and nothing to CNPG; every reader reads the warehouse. There is no per-dataset
shadow list, no per-dataset cutover list and no soak. `shadowDatasets` and `cutoverDatasets`
are removed from Helm, Compose and `ServiceRadar.Analytics.StarRocks.Env`; the reader and
destination code that branches on them (`Readers.mode_for/1`, `Destination.persist_after_cnpg/3`,
`ack_cnpg_batch/4`) collapses to one branch on `enabled`.

This replaces the earlier fixed order (shadow, parity, cutover, consumers migrated, soak, stop
writes, retirement hold, drop). The dual-write existed to make a cutover reversible by keeping
CNPG current; the product decision is that an installation that enables the warehouse does not
need that, and the cost of keeping two stores for every dataset is not worth the reversibility.

Consequences, accepted deliberately:

- **No per-dataset rollback.** With CNPG no longer written, returning one dataset's reads to CNPG
  would serve history that stopped when the warehouse was enabled. So the switch does not exist.
  Disabling StarRocks entirely resumes CNPG writes; CNPG then lacks everything written while the
  warehouse was on, and the operator documentation states it.
- **Readers not yet moved show nothing.** Writes stop for every dataset at once, including
  datasets whose readers still query CNPG (OTel, sysmon, MTR, BMP, service status, and the direct
  readers inventoried in task 5.1). Until a reader is moved, it SHALL report "unavailable with
  StarRocks enabled" rather than read a CNPG table that is silently frozen: a frozen table looks
  healthy and is wrong, which is worse than an explicit gap. Moving readers is therefore the
  critical path of this change, not a follow-up.
- **A warehouse outage is a telemetry outage.** A failed load is not acknowledged and JetStream
  redelivers; there is no CNPG fallback write. Stream retention bounds how long an outage can
  last without loss, and is stated in operator docs.
- **CNPG storage is dropped separately.** Enabling the warehouse never drops CNPG hypertables.
  A reviewed migration drops them once no reader references them; that is the only remaining
  one-way step, and it has no hold period.

Parity (Decision 2) still gates each warehouse reader: it proves a reader's queries answer the
same as CNPG's before that reader ships. It no longer gates writes.

### 2. Parity is established by diffing results, not by reading SQL

The `metrics` regression was invisible in review: `SUM(value)` is a reasonable-looking
translation of `rate`. It was obvious the moment the two backends answered the same query over
the same rows. The gate is therefore a harness that (a) extracts the query shapes the product
actually sends for a dataset, (b) seeds both backends with the same synthetic rows, including
the adversarial ones for that dataset (counter wrap, reset, missed poll, NULL dimension, a
limit smaller than the bucket count), and (c) compares result sets. A difference is either
fixed or recorded as a deliberate, documented deviation (for example `PERCENTILE_APPROX`).
The no-mistakes pipeline already built such a harness ad hoc for the rate fix; this makes it a
repository target so it runs on every change to either dialect.

### 3. Refuse, never ignore

`rollup_stats:` and `other:true` are parsed into the plan and the StarRocks dialect never
looks at them. The fix is structural rather than case by case: the dialect declares which plan
features it consumes, and a plan carrying a feature it did not consume is an error. A new SRQL
clause then fails closed on StarRocks until someone implements it, instead of returning
plausible rows.

### 4. Rollups live in the warehouse as async materialized views, partitioned by day

CNPG answers `rollup_stats:severity`, the trace RED/summary cards and service availability from
Timescale continuous aggregates. Their warehouse equivalents are day-partitioned async MVs, as
0017 established, so a refresh touches only the days that changed. `RollupFreshness` already
routes a stale or missing MV to the raw table; new rollups use the same gate.

### 5. Table model: primary-key tables stay the default

Logs, events, spans and metric points are append-only, which argues for duplicate-key tables
(no primary index, less memory). But delivery is at-least-once from JetStream, and a
duplicate-key table turns a redelivery into a double count that no later step can detect.
Primary-key tables with a persistent index, partitioned by day, keep replay idempotent, and
only recent partitions' indexes are hot. Decision: keep primary keys. Revisit per dataset only
with measured memory evidence, and only together with a dedupe story for that dataset.

Flows keep a primary key regardless: attribution updates rows in place.

### 6. Maintenance is sized to the smallest supported node

The partition rebuild copies and catches up by hour, not by day; resume bookkeeping is by the
same unit. A memory-limit error lengthens the retry interval well beyond the migrator's normal
60 seconds, and progress is logged as units remaining. Peak storage during a rebuild stays
about twice the in-retention warehouse, by the earlier decision to keep rollups alive through
the copy.

### 7. Log search

Substring search becomes a scan bounded by day partitions and the rest of the predicate.
StarRocks offers n-gram bloom-filter and inverted indexes; whether the inverted index is
available in shared-data mode on the deployed version is NOT established here. Task 2.5
measures it. If it is not available, the documented behaviour is "search is bounded by time
range and structured filters", not a promise of fast free-text search over a year.

## Risks / Trade-offs

- No rollback per dataset, and disabling StarRocks leaves a gap in CNPG. Accepted: see Decision 1.
- Readers that still query CNPG go dark the moment the warehouse is enabled. Mitigated only by
  moving them, in the order of section 5 of the tasks, and by the explicit "unavailable" state
  instead of silently stale data.
- A warehouse outage stops telemetry persistence; JetStream retention is the buffer.
- Freshness is the Stream Load batch interval (seconds). A live log tail shows it; dashboards do
  not. Stated in operator docs rather than hidden.
- Trace-by-id is a point lookup against object storage: tens to low hundreds of milliseconds
  with a warm cache. Acceptable for a detail page; measured in task 3.5.
- More of the product depends on the warehouse being up. An installation that cannot accept that
  leaves StarRocks off and keeps today's behaviour.

## Migration Plan

1. Remove the dual-write and the per-dataset lists (task 5.2): enabling StarRocks makes every
   dataset warehouse-only.
2. Move every CNPG telemetry reader to the warehouse (tasks 5.1, 5.4, 2.4, 3.x), highest-traffic pages
   first: dashboard cards and sparklines, MTR, logs and events pages, OTel, sysmon, BMP, service
   status. Each reader ships behind its parity comparison.
3. Backfill history that should outlive the switch (task 5.5), then drop CNPG telemetry storage
   by reviewed migration (task 5.6).

## Open Questions

- Whether history already in CNPG is backfilled into the warehouse before its hypertable is
  dropped, or allowed to age out. Proposed: backfill flows and metrics (large, valuable), let
  the rest age out under their existing CNPG retention before the drop.
