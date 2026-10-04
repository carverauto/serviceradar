## Context

Today:

```
netprobe sidecar -> agent -> gateway -> core StatusHandler
  -> FlowAttribution.persist/4 -> Persistence.insert_current_rows/1
  -> CNPG platform.flow_process_attribution_current   (direct write, upsert)
Correlator (every ~2 min, single replica):
  read <= 5,000 unattributed flows from StarRocks ocsf_network_activity
  -> VALUES list into CNPG -> match against flow_process_attribution_current
     (+ ocsf_agents node IPs, public_endpoints_current, workload_identity_current)
  -> publish stamps on events.flow.attribution
  -> EventWriter FlowAttributionUpdates -> partial PK update of ocsf_network_activity
Retention: ctid-bounded DELETE batches older than the retention window.
```

The CNPG table is not current state in any useful sense: every row is an observation that is
irrelevant after the correlation window (15 min) plus skew (15 min). Keeping it in a
transactional table with an upsert, row-level deletes and eight indexes is what produced the
churn, the 0% HOT rate, the 17 GB footprint and the deadlocks between the prune and ingest.

## Goals / Non-Goals

- Goals: no row-level churn anywhere in the attribution path; observations on JetStream;
  correlation in the warehouse; the CNPG table and its jobs deleted; correlation p95 bounded and
  measured; behaviour without StarRocks explicit.
- Non-goals: changing the match semantics or precedence; changing how attributed flows are read
  by the UI or SRQL (they keep reading persisted attribution columns on `ocsf_network_activity`);
  a CNPG fallback; migration or dual-write machinery (only the team's own demo deployments run
  this).

## Decisions

### 1. Observations travel on JetStream and EventWriter persists them

`StatusHandler`'s flow-attribution branch publishes each admitted `FlowAttributionEvent` batch
to `flows.attribution.observations` instead of calling `Persistence`. The subject joins the
flow demand domain (the dedicated `flows` stream, alongside `flows.raw.*`), so a NetFlow-scale
burst cannot starve other EventWriter consumers, and admission stays bounded as
`harden-flow-attribution-pipeline` requires. A new EventWriter processor writes the rows to
StarRocks with Stream Load like the other warehouse processors. Core publishes; it never
writes the warehouse. This closes the direct-write exception in the current design.

### 2. Append-only Duplicate Key table with daily partitions and partition TTL

```sql
CREATE TABLE IF NOT EXISTS serviceradar.flow_process_attribution_observations (
  observed_at DATETIME NOT NULL,
  `partition` VARCHAR(128) NOT NULL,
  proto INT NOT NULL,
  local_ip VARCHAR(64) NOT NULL,
  local_port INT NOT NULL,
  remote_ip VARCHAR(64) NOT NULL,
  remote_port INT NOT NULL,
  agent_id VARCHAR(256) NOT NULL,
  attribution_key VARCHAR(512) NOT NULL,
  pid INT, comm VARCHAR(256), container_id VARCHAR(256), ...   -- remaining payload columns
)
DUPLICATE KEY (observed_at, `partition`, proto, local_ip)
PARTITION BY date_trunc('day', observed_at)
DISTRIBUTED BY HASH(`partition`, local_ip) BUCKETS 8
PROPERTIES ("replication_num" = "3", "partition_live_number" = "30");
```

- **Duplicate Key, not Primary Key.** Every observation is a new row. Nothing is updated, so
  there is no upsert path, no delete vector, no primary index to maintain, and no compaction
  pressure from rewriting the same key thousands of times an hour.
- **Expiry by partition drop, daily partitions.** Retention is a number of days, applied as
  `partition_live_number` like every other warehouse dataset. Daily partitions keep the
  partition count small for long retention (30 days is 30 partitions; hourly would be 720) and
  match the other datasets, so the existing retention applier handles this table unchanged.
  Old data goes by dropping a partition: a metadata operation with no per-row cost. This
  replaces the ctid prune job.
- **Retention floor.** The minimum is 1 day. Correlation needs only the 15-minute window plus
  15 minutes of skew, but with daily partitions a value of 1 still keeps the current day, and
  the newest flows near midnight can need the previous day's partition, so the floor is stated
  as 1 day and the applier never sets fewer than 2 live partitions for this table.
- **Duplicates are expected.** The same socket is observed repeatedly. Correlation already
  takes the newest qualifying observation per key and rank, so repeats cost storage (a few
  days of rows) but not correctness. EventWriter may coalesce identical
  `(partition, attribution_key)` rows within one Stream Load batch, but only if the load test
  shows the volume matters.
- **Why a Primary Key design would reintroduce the problem.** A StarRocks Primary Key table
  keyed on `(partition, attribution_key)` with an upsert on every observation and row deletes
  for retention reproduces the CNPG pattern in a different engine: every upsert writes a delete
  marker plus a new row version, the persistent primary index churns, compaction has to keep
  rewriting segments for keys that change every few seconds, and retention deletes add more
  delete vectors. The cost moves from autovacuum to compaction but grows with churn the same
  way. Append-only plus partition drop has no per-row maintenance at all.
- **Retention defaults to 30 days.** Observations answer incident-response questions (which
  process was talking to this address last Tuesday) beyond what the per-flow stamp carries, so
  they are kept as a dataset in their own right, shorter than the 365-day default because of
  volume. Operators change it on the Data retention settings page (Decision 8); demo sets 1 day.

### 3. Correlation is one in-warehouse statement

The correlator runs one StarRocks query per pass: recent unattributed flows from
`ocsf_network_activity` joined to `flow_process_attribution_observations` within
`[flow.time - skew, flow.time + skew]`, ranked by the existing precedence. The candidate
families and their order are unchanged from `harden-flow-attribution-pipeline`'s requirement
*Correlation Is Protocol-Aware And Exact-First*: exact bidirectional tuple, wildcard listener,
relaxed UDP service-port, ICMP without port equality, node-SNAT, then public-endpoint classes
(Gateway, LoadBalancer/ExternalIP, other). Within a rank the newest observation wins; ambiguous
relaxed candidates keep their ambiguous outcome.

Both partition pruning (`observed_at` within the last window+skew) and the time-bounded flow
read keep the scanned data to the live partitions. The batch limit stays a parameter.

Small control-plane inputs needed during matching come from CNPG and are passed as bound
parameters: registered agent node IPs (node-SNAT) and public endpoint backends. Both are small
(tens to low thousands of rows) and change slowly; core reads them once per pass. This keeps
CNPG authoritative and avoids pulling them through the JDBC catalog on every pass.

### 4. Stamps keep the existing JetStream partial-update path

Matches are published on `events.flow.attribution` and applied by `FlowAttributionUpdates` as
a partial primary-key update of `ocsf_network_activity`, exactly as today, carrying the
`flow_attribution_update_version` sequence (control-plane, stays in CNPG). An in-warehouse
`INSERT ... SELECT` would be one statement shorter but would make core a direct warehouse
writer and bypass EventWriter's versioning and back-pressure; the extra hop is cheap at
thousands of stamps per pass.

### 5. Workload identity is enriched after the match, by key

The current CTE joins `workload_identity_current` (about 90k rows, ~300 MB on demo) inside
every pass, and the workload backfill rewrote the observation table to copy it in. Instead,
after the warehouse returns the matched rows (at most the batch limit), core looks up workload
identity in CNPG by `(agent_id, container_id)` for those rows only, and the published stamp
carries it. CNPG remains the source of truth; no pass scans the whole workload table; there is
no backfill. Rejected: reading `workload_identity_current` through the `cnpg_platform` JDBC
catalog inside the warehouse statement, which would ship most of that table out of CNPG on every
pass.

### 6. Without StarRocks, attribution is disabled and says so

NetFlow already requires StarRocks. When the warehouse is not configured, the observation
publisher and the correlator do not run, and the flow-attribution health surface reports
`attribution_disabled: starrocks_required` instead of silently storing observations nobody can
correlate. No CNPG fallback is kept.

### 7. Observability through the metrics pipeline

Correlator pass duration, flows read, matches by strategy, stamped count, observation lag
(newest observation age), ingest rate, and live partition count are emitted as metrics on
JetStream like every other metric, so a slow or failing pass is visible before attribution is
lost.

### 8. One DB-backed Data retention setting for every warehouse dataset

Today retention is per dataset but env-only: `Env` reads
`SERVICERADAR_STARROCKS_RETENTION_DAYS_<DATASET>` (Helm `analytics.starrocks.retentionDays.<dataset>`,
Compose `STARROCKS_RETENTION_DAYS_<DATASET>`), and `Retention` applies
`ALTER TABLE ... SET ("partition_live_number" = N)` to each dataset's tables at boot, retrying with
capped backoff until the Frontend answers. Changing a value means editing Helm and restarting core.

- **Storage.** A CNPG control-plane settings resource holds one row per dataset: retention days,
  updated_by, updated_at, and the last applied value, status (`applied`, `pending`, `failed`)
  and error. It is deployment-scoped, like other platform settings.
- **Seed default.** The env/Helm/Compose value seeds a dataset's row when none exists. After
  that the stored setting wins; the env value is the default, not an override. Datasets: flows,
  metrics, logs, events, mtr, otel, traces, bmp at 365 days (the existing default), attribution
  at 30.
- **Apply without restart.** Saving a setting updates the row and asks the existing applier to
  re-apply that dataset's statements. The applier keeps its retry-with-backoff behaviour and
  records the outcome on the row, so the page shows whether the warehouse took the value. Boot
  still applies every dataset from the stored settings, so a warehouse rebuilt from DDL defaults
  converges again.
- **Validation.** Each dataset has a floor (attribution 1 day; the others keep today's minimum)
  enforced on save and by the applier. Large values show a storage warning on the page but are
  allowed.
- **UI.** One "Data retention" Settings page in web-ng, RBAC-gated (view vs manage), listing each
  dataset with its effective value, seed default, and last-applied status and time.

## Risks / Trade-offs

- Observation volume: 30 days of raw rows at a real install's rate. Demo's rate (on the order of
  10k observations a minute) is about 430M rows over 30 days, modest for a Duplicate Key table in
  shared-data StarRocks; the load test measures the steady-state size and per-day storage, which
  the retention page's storage warning uses.
- Correlation latency now depends on warehouse query capacity. The load test gates on p95.
- Stamps for a flow that arrives after its observations have expired are lost, as today; the
  window is unchanged.

## Cutover

Switch in one release; the attribution window is ephemeral, nothing to migrate.

## Decided

- Observation retention: operator-configurable, default 30 days, daily partitions, floor 1 day;
  demo sets 1 day in its Helm values.
- Retention for every warehouse dataset moves to one DB-backed Data retention setting.
- Coalescing duplicate observations within an EventWriter batch is done only if the load test
  shows the volume matters.
