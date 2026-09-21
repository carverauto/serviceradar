# Design: StarRocks as the telemetry system of record

## Context

Where things stand, in a deployment that has cut flows over: flows are read only from the
warehouse; metrics are being cut over; logs and events are shadow-written and read from CNPG;
nothing else is in the warehouse. All four warehouse tables are partitioned by day with
per-dataset retention, and the three hourly rollups are day-partitioned async materialized
views. CNPG still receives every telemetry write.

Where the money is: flows and scalar metrics dominate CNPG telemetry storage by roughly two
orders of magnitude over every other dataset, which is why they are retired first.

## Goals / Non-Goals

- Goals: every append-only telemetry dataset served from, and eventually stored only in, the
  warehouse; no chart that silently shows different numbers after a cutover; CNPG reduced to
  transactional state; maintenance safe on a modest warehouse.
- Non-Goals: moving inventory, identity, credentials, configuration, alert state or jobs;
  replacing the JetStream-first single-owner write path; making StarRocks mandatory (an
  installation without it keeps CNPG telemetry exactly as today).

## Decisions

### 1. The order is fixed, per dataset, and only the last two steps are one-way

`shadow write -> dialect parity proven -> reads cut over -> non-UI consumers migrated -> soak ->
stop CNPG writes -> retirement hold -> drop CNPG storage`.

The two waits are distinct. The **soak** precedes "stop CNPG writes", because that is the first
irreversible step: it runs with reads cut over, non-UI consumers migrated and CNPG still
written, so a problem found during it is still a configuration revert. The **retirement hold**
is the shorter wait between "stop CNPG writes" and "drop CNPG storage": it proves nothing still
reads the now-frozen CNPG history before that history is destroyed.

Everything up to and including "reads cut over" is reversible by removing the dataset from
`cutoverDatasets`, because CNPG is still written. Flows are the existing exception: they have no
CNPG read path, so removing `flows` refuses flow reads rather than falling back. "Stop CNPG
writes" ends reversibility for new data; "drop CNPG storage" ends it for history. They are
separate operator actions with separate configuration, and neither is implied by the other or
by any release.

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

- Retiring CNPG writes removes rollback. Mitigated by the soak before it, by the retirement
  hold before the drop, by the two separate operator actions, and by doing the
  largest-saving, longest-proven dataset (flows) first.
- Freshness is the Stream Load batch interval (seconds). A live log tail shows it; dashboards do
  not. Stated in operator docs rather than hidden.
- Trace-by-id is a point lookup against object storage: tens to low hundreds of milliseconds
  with a warm cache. Acceptable for a detail page; measured in task 3.5.
- More of the product depends on the warehouse being up. An installation that cannot accept that
  leaves StarRocks off and keeps today's behaviour.

## Migration Plan

Per dataset, in this order: flows (already warehouse-only for reads), metrics, logs, events,
then the new datasets as each gains a warehouse table. Each completes the sequence in Decision 1
before the next starts its one-way steps; reversible steps may overlap.

## Open Questions

- Soak period before write retirement: proposed 14 days of clean operation per dataset.
  Retirement hold before the storage drop: proposed 7 days with no reader errors.
- Whether history already in CNPG is backfilled into the warehouse before its hypertable is
  dropped, or allowed to age out. Proposed: backfill flows and metrics (large, valuable), let
  the rest age out under their existing CNPG retention before the drop.
