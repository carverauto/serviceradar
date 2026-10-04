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

### 2. Append-only Duplicate Key table with hourly partitions and partition TTL

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
PARTITION BY date_trunc('hour', observed_at)
DISTRIBUTED BY HASH(`partition`, local_ip) BUCKETS 8
PROPERTIES ("replication_num" = "3", "partition_live_number" = "3");
```

- **Duplicate Key, not Primary Key.** Every observation is a new row. Nothing is updated, so
  there is no upsert path, no delete vector, no primary index to maintain, and no compaction
  pressure from rewriting the same key thousands of times an hour.
- **Expiry by partition drop.** With hourly partitions and `partition_live_number = 3`, the
  warehouse keeps the current hour plus at least two full hours, comfortably more than the
  30-minute window plus skew, and removes old data by dropping a partition: a metadata
  operation with no per-row cost. This replaces the ctid prune job.
- **Duplicates are expected.** The same socket is observed repeatedly. Correlation already
  takes the newest qualifying observation per key and rank, so repeats cost storage (a few
  hours of rows) but not correctness. EventWriter may coalesce identical
  `(partition, attribution_key)` rows within one Stream Load batch to cut volume; that is an
  optimization, not a requirement.
- **Why a Primary Key design would reintroduce the problem.** A StarRocks Primary Key table
  keyed on `(partition, attribution_key)` with an upsert on every observation and row deletes
  for retention reproduces the CNPG pattern in a different engine: every upsert writes a delete
  marker plus a new row version, the persistent primary index churns, compaction has to keep
  rewriting segments for keys that change every few seconds, and retention deletes add more
  delete vectors. The cost moves from autovacuum to compaction but grows with churn the same
  way. Append-only plus partition drop has no per-row maintenance at all.
- **Retention is deliberately hours, not the warehouse default of 365 days.** These rows are
  correlation input, not history. The durable result, the attribution stamped onto each flow,
  lives on `ocsf_network_activity` and keeps that dataset's retention. See open questions.

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

## Risks / Trade-offs

- Observation volume in StarRocks is a few hours of raw rows rather than one row per key.
  Demo's rate (on the order of 10k observations a minute) is small for a Duplicate Key table;
  the load test confirms the steady-state size.
- Correlation latency now depends on warehouse query capacity. The load test gates on p95.
- Stamps for a flow that arrives after its observations have expired are lost, as today; the
  window is unchanged.

## Cutover

Switch in one release; the attribution window is ephemeral, nothing to migrate.

## Open Questions

- Observation retention: keep hours (proposed: `partition_live_number` 3 with hourly
  partitions) as an explicit exception to the 365-day warehouse default, since the durable
  attribution lives on the flows? Or keep longer for debugging attribution after the fact?
- Should EventWriter coalesce duplicate `(partition, attribution_key)` rows within a batch from
  the start, or only if the load test shows the volume matters?
