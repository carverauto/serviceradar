# Design: Partitioned, stream-backed alert evaluation at fleet scale

## Context

The rates this design must meet, the assumptions behind them and the audit of
today's path are in `capacity.md`. The short version: about 40,000 alert
candidates/s sustained and 100,000/s in a 5-minute burst, against a current
ceiling of about 90 evaluations/s cluster-wide. The five worst breaking points
are in `capacity.md` 2.3.

Today's alert path, as built by `refactor-durable-alert-admission` (#5473) and
the lifecycle pending admission PRs (#6304, #6317):

1. An EventWriter processor stores its rows, then calls
   `StatefulEvaluationLedger.evaluate_once/2`. The ledger reads and writes one
   CNPG row per event.
2. `Inbox.admit/2` takes a global advisory lock. It reads every active rule
   for the signal, filters with `RuleMatcher`, and computes backlog aggregates
   over the whole inbox. For every (record, rule) pair it inserts a work row
   carrying the full record and the full rule revision (about 12.7 KB for a
   Falco event). It also schedules an Oban wake-up per rule.
3. An `EvaluationWorker` (queue `alerts`, 5 per node) runs `Owner.advance/1`.
   That is one transaction per occurrence, which restores every snapshot of
   the rule `FOR UPDATE`, runs the state machine on an ETS working copy,
   upserts changed snapshots, writes a receipt and deletes the work row.
4. Overload returns `{:overloaded, _}`. The batch fails and is redelivered,
   and after `max_deliver=5` it is terminated.

The state machine's logic is right and is kept. What fails is everything
around it: per-occurrence CNPG round trips, one serialized admission, a byte
budget in a relational table, and redelivery as the only backpressure.

## Goals / Non-Goals

Goals:

- Meet the `capacity.md` targets with stated headroom on 3-6 core replicas.
- Never lose a signal or its evaluation to backpressure. Overload becomes lag.
- Fire each incident exactly once, and count each occurrence exactly once,
  across crashes, failover, redelivery and rebalancing.
- Preserve every current rule behaviour (section "Semantics preservation").
- Keep CNPG as the control plane only. Keep telemetry JetStream-first and
  StarRocks-only when enabled.
- Remove the inbox, ledger and pending-admission machinery outright.

Non-Goals:

- A new rule language, new rule features, or multi-rule correlation. The one
  possible exception is raw log rules (Q6).
- Moving per-series anomaly detection back to core. That stays at the edge
  (`move-anomaly-detection-to-edge`).
- Flow alerting. Flows stay StarRocks-only and are not evaluated
  (`scale-netflow-ingest-isolation` owns flow ingest).
- An edge-resident rule engine. Alert availability remains core availability
  (`docs/docs/architecture.md`).
- Multitenancy. Everything is scoped to the one deployment.

## Architecture

```
 collectors / gateways / agents
   | batched, partitioned publish (logs.v1.pNN.*, events.v1.pNN.*, metrics.v1.pNN.*)
   v
 JetStream source streams (R3, DiscardNew, sized for an outage window)
   | shared durables, every core replica
   v
 EventWriter worker (per replica)
   decode -> normalize -> promote
     |-- store: warehouse coalescer (StarRocks) or CNPG ------------+
     |-- route: compiled rule index -> candidates                   |
     |      async publish to alerts.candidates.v1.pNN, await PubAck |
     +-- ack source message only after BOTH complete <--------------+
   v
 JetStream candidate streams ALERT_CANDIDATES_V1_S0..S3
   (64 logical subjects, Limits, DiscardNew, no MaxAge, purged behind checkpoints)
   | ordered consumer per partition, from checkpoint seq + 1
   v
 Partition owner (one per partition, leased, on some core replica)
   dedupe ring -> deterministic state machine (ETS) -> effects as data
     |-- effect commit (CNPG, fenced by lease epoch, idempotent by fire key)
     |-- checkpoint commit (CNPG, fenced: dirty groups + dedupe slices + seq)
     +-- purge subject up to checkpoint seq
   v
 alerts, history, notification routing jobs, DurablePublish outbox
```

Control inputs (rule disable/delete, stale-anomaly maintenance, operator
alert actions, cutover import end) are messages on the same partition
subjects, so they are ordered with the candidates they affect.

## Decisions

### D1: Compiled rule index at the router (direction 1: adopt)

Each EventWriter replica compiles the active stateful rules and promotion
rules into an immutable index per signal:

- a subject-prefix trie over `subject_prefix`;
- equality buckets on the most selective indexable predicate of each rule
  (`metric_name`, `log_provider`/`service_name`, an `attribute_equals`
  key=value pair, event class);
- a sorted severity-floor list for `severity_number_min`;
- a catch-all list for rules with no indexable predicate (`always`,
  `body_contains` only). Rule validation warns when a rule lands there for a
  high-rate signal.

Routing a record unions the buckets it hits. It then runs the existing
`RuleMatcher` predicate, unchanged, on those candidates only. The cost is
O(trie depth + candidate rules), about 5 us for a log or event and 1 us for a
metric point (gate G1). The anomaly-open subject guard from the pending
eligibility fix (`RuleMatcher.event_candidate?/2`) becomes the anomaly-open
rule's index anchor; it is used as landed, not rewritten.

The index is rebuilt when a rule changes, not on a TTL. Rule writes commit a
`rule_set_version` bump through the existing transactional outbox, and every
replica rebuilds on the notification, with a periodic version check as the
backstop. The compiled index is published with one `:persistent_term` write
per rule change. That replaces today's 5 s TTL refreshes, which each write
`:persistent_term` and so trigger a global GC pass (`capacity.md` S14).

The router also computes, per candidate rule, the group key (`Record.build_group/2`),
the metric violation increment (`MetricCondition.tag_metric_violation/2`),
the recovery-match flag (`rule_recovers_event?/2`), and, for anomaly-open
rules, the seasonal disposition (`SeasonalStateStore.lookup_window_disposition`,
behind a small TTL cache). It stamps all of them into the candidate. The
evaluator then never reads an external store to decide (D5).

Rejected: matching inside the evaluator against every rule. That puts every
record on the candidate stream, which is today's cost moved to NATS.

### D2: JetStream candidate streams with versioned subject partitioning (direction 2: adopt, adapted)

A candidate goes to `alerts.candidates.v1.pNN`, where `NN = H(rule_id,
group_key) mod P` under a versioned hash (`partition_map_version`). Logical
partitions map to physical streams as in `add-edge-record-stream-partitioning`
task 1.2: a complete, non-overlapping table from logical partition to physical
stream, stored in CNPG (`alert_partition_map`). The default is P = 64 on 4
physical streams (`ALERT_CANDIDATES_V1_S0`..`S3`, 16 subjects each). Several
physical streams spread Raft leaders across NATS servers. P and the map are
fixed per installation. Changing them is the re-partition procedure under
"HA and rebalancing".

Stream shape: file storage, R3 (capped to `nats.replicas`), S2 compression,
Limits retention, DiscardNew, `MaxAge` 0, finite `max_bytes` from the
JetStream profile (Q4), and the duplicate window at its minimum, because
deduplication belongs to the evaluator (D6). Partition owners delete consumed
messages by purging their subject up to the committed checkpoint sequence.
Nothing ages out unprocessed.

Per-rule CNPG inbox rows are gone. The candidate is a protobuf
`serviceradar.alerts.v1.Candidate`: rule id and revision, partition and map
version, kind (match, recovery match or control), group key and values, event
time, signal, source key and stored-record reference, the stamped router
outputs from D1, and the evaluation projection (D8). Its candidate id is a
128-bit hash of (rule id, source key, kind).

Rejected: evaluating directly on device-partitioned source streams. Rules
group by gateway, by service or globally, so one rule's groups span every
source partition. Counts would need a cross-partition merge with
coordinated firing, which is the hard problem this design avoids.

### D3: Partition ownership by fenced CNPG leases (direction 3: adopt)

`platform.alert_partition_leases` holds one row per partition: owner node,
`epoch` (bigint fencing token), `expires_at`, map version. Leases are taken
and renewed by compare-and-set using database time (`now()`), never node
clocks. TTL is 15 s and renewal every 5 s (CNPG runtime settings). Acquiring a
lease increments `epoch`.

Every effect commit and checkpoint commit for partition p runs in one
transaction that first asserts that the lease row has the owner's epoch and
has not expired, using a row lock. A stale owner's commit therefore fails, and
it stops. Rows, not session advisory locks, carry ownership, so leases work
through the transaction-pooled PgBouncer path. Session locks leak there.

Placement uses rendezvous hashing over live core replicas that have
repository access and advertise the `alert-partitions-v1` capability. A
replica takes the free or expired partitions it prefers and hands off the
ones it no longer prefers (see "HA and rebalancing").

Rejected: Horde/ProcessRegistry ownership, which has no fencing token that a
database commit can check (the #4511 loss path). Rejected: JetStream KV
leases, because the fence must be checked in the same transaction as the
alert write, and that transaction is in CNPG.

### D4: Deterministic in-memory state with incremental checkpoints (direction 4: adopt)

Each owner keeps an ETS table per partition keyed by `{rule_id, group_key}`.
The value is today's snapshot shape (bucket counts, current bucket, last seen,
last fired, last notification, cooldown, alert id, first seen, diagnostics)
plus four fields: `incident_seq` and `renotify_ordinal` for fire keys (D5),
`operator_terminal` (D9), and `evaluated_through_seq`. The existing
`StateMachine`, `Bucketing`, `Diagnostics`, `MetricCondition` and
`EdgeAnomalyDisposition` decisions are reused. They are refactored so that
they return effects as data instead of performing Ash writes (D5).

A group whose window is empty, with no open incident and no running cooldown,
is evicted. It equals the default state, so dropping it changes no outcome.
This bounds memory to active groups (`capacity.md` 1.4).

Checkpoint: every 30 s or 50,000 candidates, whichever comes first, and on
handoff (Q3). One fenced transaction:

1. upserts the dirty groups into `stateful_alert_rule_states`, which gains
   `partition` and `map_version` columns, and deletes evicted ones;
2. inserts the closed dedupe slices (D6) and deletes slices older than the
   horizon;
3. advances `alert_partition_checkpoints(partition, map_version, seq, epoch)`.

Writes scale with dirty groups, not total state (`capacity.md` 1.4: about
1,700 rows/s typical). Rejected: a whole-partition state blob per checkpoint.
Its write volume grows with total state rather than with change, and the
existing table, which the UI reads, would go stale.

Recovery loads the partition's rows and slices, then replays from
checkpoint seq + 1 with an ordered consumer (D6). Replay at the default
interval is about 19,000 candidates, under 2 s.

### D5: Exactly-once by deterministic replay and idempotent effects (direction 4: adopt)

The evaluator is a pure function F(state, candidate) -> (state', effects).
Effects are data: create incident, resolve incident, renotify, record
history, update incident metadata, maintenance receipt. Each effect has a
**fire key** derived only from the state and the candidate:

- incident alert id = UUIDv5(rule_id, group_key, incident_seq); the fired
  OCSF event id is derived from it;
- renotify = (alert id, renotify_ordinal); resolve = (alert id, "resolve");
- history row id = UUIDv5(kind, alert id, ordinal);
- notification routing job unique key = (alert id, kind, ordinal);
- incident metadata updates carry `(map_version, partition, seq)` and apply
  only when newer than the stored value (`alerts.evaluation_seq`).

Incident counters (`incident_occurrence_count`, last seen, window count) live
in group state. The alert row's metadata is written once per effect commit
with the latest values, not on every record. That removes the hot-row update
in `sync_active_incident/4` (`capacity.md` S10).

Effect commit: after each pulled batch (up to 500 candidates or 50 ms) that
produced effects, one fenced CNPG transaction applies them with
insert-if-absent and guarded updates. Generated OCSF events go through the
existing DurablePublish outbox in that same transaction, so publication stays
JetStream-first. Ash notifications are sent after commit
(`Inbox.notify_after_commit/1` semantics, moved to the owner).

Decisions never depend on an effect's outcome. A transient failure (store
unavailable, lock timeout, fence lost) aborts the commit, and the owner
recovers from its checkpoint and replays: one crash-only path, tested by G3.
A permanent per-effect failure (a constraint or validation error) is written
to `alert_effect_failures` with diagnostics and raises a health signal, and
the state keeps its planned identity. Today, a failed create leaves the
snapshot without an alert id and re-fires on every match without paging
anyone (the `resolved_device_uid/1` comment). That loop goes away.

Content may depend on external reads, for example device attribution at
fire time. The first committed write of a fire key wins and a replay is a
no-op, so content reads cannot cause duplicates.

Promotion alerts created by `LogPromotion` become idempotent by
UUIDv5(promotion_rule_id, event_id) with insert-if-absent. That is the only
thing the per-event ledger guarded for them.

### D6: Backpressure is lag, never loss (direction 5: adopt)

Consumption: each owner reads its subject with an ordered consumer: an
ephemeral pull consumer with `AckPolicy none`, `DeliverByStartSequence =
checkpoint + 1`, recreated from the last applied sequence on any gap. No
acknowledgement, no `ack_wait`, no `max_deliver`. A slow or stopped owner can
never cause a redelivery storm or a terminal drop. Retention is the explicit
purge behind each checkpoint (D2).

Duplicates: a source redelivery can republish a candidate whose earlier
publish succeeded. The owner keeps a ring of 128-bit candidate ids for the
duplicate horizon H (default 10 min) in closed 10 s slices. A repeated id is
skipped and counted. Closed slices are persisted with the checkpoint, so a
new owner suppresses duplicates exactly as the old one would have. Ids are
128-bit because a collision silently drops a real occurrence. The residual
case, a republish later than H, is in Q5.

Publishing: the router publishes a batch's candidates asynchronously and
awaits every PubAck. A refusal (stream full, NATS unavailable, timeout) is
retried in place for the unacknowledged subset, with capped backoff and no
attempt limit. The router sends `+WPI` progress acknowledgements on the
source messages so they are not redelivered while it waits. It never NAKs
for a publish failure, so candidates of one source batch keep their order.
A health event is raised after 30 s of continuous retry.

When a stream is full, publishers are refused; accepted messages are never
evicted. The chain of buffers is in `capacity.md` 1.5: candidate streams,
then source-stream lag, then refusal at the collector (Q8).

Poison: a candidate that crashes the pure evaluator at the same sequence on
three consecutive attempts is copied to `ALERT_CANDIDATES_DLQ_V1` (DiscardNew,
no MaxAge) with its error. Its sequence is recorded as a skipped disposition
in the checkpoint, health turns critical, and the partition continues. The
underlying record is already stored, and redrive replays the DLQ entry
through the evaluator after a fix. This is the audited terminal disposition,
not a silent drop. Only exceptions inside F qualify; store errors are
transient by definition.

### D7: CNPG holds only lifecycle, checkpoints, leases and rule config (direction 6: adopt)

The new CNPG tables are `alert_partition_leases`, `alert_partition_checkpoints`,
`alert_partition_dedupe_slices`, `alert_partition_map`, `alert_effect_failures`,
`alert_maintenance_receipts`, an immutable `stateful_alert_rule_revisions`, and
`AlertEvaluationSettings`. Existing tables kept: `stateful_alert_rule_states`
(now the incremental checkpoint), `stateful_alert_rule_histories`, `alerts`
(adds `fire_key` unique and `evaluation_seq`), and the rule resources.
Telemetry about the pipeline goes through JetStream and EventWriter. None is
written directly to CNPG or StarRocks.

### D8: The candidate carries an evaluation projection, not the record (adapted)

Today's work row embeds the whole record and the whole rule. The candidate
instead carries every field that any compiled rule or the alert builder
reads. That is the union of match, group, template and diagnostic field
references, computed when the index is compiled, plus a fixed core
(identity, time, severity, device, subject, message, observables). It also
carries a reference to the stored record. Each projected value is carried
whole. Fields that no rule reads are not copied, and the stored record keeps
them. That is projection, not truncation. A rule edit that references a new
field recompiles the projection, and candidates routed afterwards carry it.

The rule itself is referenced by (rule_id, revision). Revisions are
immutable rows, cached by owners, so a replay evaluates exactly the revision
that was routed.

### D9: Ordered control inputs replace every external read a decision made

Today some decisions read mutable rows at evaluation time: whether the rule
is still enabled, the alert's current status (renotify and recovery treat an
operator-resolved alert as terminal), and episode liveness for stale
resolution. A replay could decide differently if those rows changed in
between. Each becomes an ordered message on the affected partitions,
published through the DurablePublish outbox in the transaction that made the
change:

- **Rule disabled or deleted:** a marker to every partition. Later
  candidates of that rule are dropped and counted, which matches today's
  durable cancellation. Delete also clears the rule's groups. Edits need no
  marker, because candidates carry their revision.
- **Operator alert action** (resolve, suppress, any status the evaluator
  reads): a message to the alert's partition, computed from the incident rule
  and group key in its metadata. The group records `operator_terminal`. As
  today, it is not renotified and does not re-fire until the group recovers.
- **Stale-anomaly maintenance:** `resolve_stale_anomalies/4` publishes a
  maintenance marker carrying `cutoff`, `now` and an immutable live-series
  snapshot id to every partition, then awaits one `alert_maintenance_receipts`
  row per partition with a bounded timeout. It returns their summed resolved
  count, which keeps today's synchronous contract.
- **Cutover import end:** see Migration.

The evaluator uses no wall clock. Time comes from event time or from the
`now` a control message carries.

### D10: Ingestion at fleet scale (direction 7)

Findings and changes, keyed to `capacity.md` S1-S5 and S13:

- **Source streams (S2).** Split the shared `events` stream into `LOGS_V1`,
  `EVENTS_V1` and `OTEL_V1` (metrics already has `metrics`). Subjects are
  partitioned by the same versioned 64-partition hash over the source device
  or address, and mapped onto physical streams (1 for small profiles, 4 at
  the design point). Streams are R3, DiscardNew and sized for a 30-minute
  outage window per profile. Partitioning here serves stream throughput and
  placement, not ordering: storage is idempotent and shared durables still
  load-balance across replicas.
- **EventWriter batching (S3).** Batchers per signal get configurable
  concurrency (default `System.schedulers_online/0 / 2`). Their batch size
  and timeout become CNPG runtime settings with code defaults. Pull batch and
  `max_ack_pending` per stream are sized from the coalescing window below.
- **Warehouse loads (S4).** A per-dataset coalescer per replica gathers rows
  from many Broadway batches. It flushes at 50,000 rows, 32 MB or 5 s, and
  acknowledges the contributing source messages only after the load succeeds,
  so the existing Stream Load knobs finally shape loads. Loads per table per
  replica stay at about 1/s or less at the design point.
- **Store and route in parallel.** Routing does not wait for the coalesced
  load. The source acknowledgement waits for both. An alert can be visible a
  few seconds before its triggering record is queryable in the warehouse.
  Alert latency is no longer tied to the warehouse flush age.
- **CNPG telemetry dual-write (S5).** Resolved by
  `extend-starrocks-to-all-telemetry` (warehouse-only when enabled). The
  CNPG-only ceiling is stated in `capacity.md` 1.6.
- **Redelivery (the dead-letter finding).** Alert-feeding durables get
  unlimited `max_deliver` with a BackOff list. Processors classify failures:
  transient ones NAK with backoff (store) or retry in place (route), and only
  permanent ones (decode or schema errors) are copied to `TELEMETRY_DLQ_V1`
  with PubAck before `+TERM`.
- **Collectors (S1).** flowgger and trapd NATS outputs pack up to N records
  or T ms per message and keep K PubAcks in flight. When the stream refuses a
  publish, they back off and spool to a bounded local file. Refusals and spool
  overflow are counted and reported in health. UDP receive drops are read
  from socket statistics and reported, so the one place a record can be
  refused is visible (Q8).
- **Single-writer processors (S13).** `ANALYTICS_PREDICTIONS`, the causal
  streams, `K8S_INVENTORY` and `TRIVY` move from the coordinator to the same
  leased-partition primitive. They partition by finding/series, prefix or
  report key, so per-key order holds and they scale out. This supersedes
  Decision 3 of `scale-event-writer-across-core-replicas` for those streams.
  Lifecycle transitions keep per-series FIFO through partition order plus
  in-place publish retry, which is what `lifecycle_pending_admissions`
  provided.

### D11: Runtime settings in CNPG

`AlertEvaluationSettings` (a singleton row with code defaults) holds the
checkpoint interval and candidate cap, lease TTL and renewal, batch size and
wait, dedupe horizon, handoff concurrency, publish retry caps, and lag
degraded/critical thresholds. EventWriter batching and coalescer limits join
the existing EventWriter runtime settings. Partition count and the physical
map are install-time rows. Stream byte sizes stay in the JetStream profile
contract (`jetstream-storage-budget`), the only place that knows the volume
size, plus a new `xlarge` profile. `SERVICERADAR_ALERT_EVALUATION_MODE` and
its Helm rendering are removed.

## Semantics preservation

| Feature | Today | After |
|---|---|---|
| Threshold N in window T | bucket counts by event time per group | same functions, in partition state |
| Grouping (`group_by`) | `Record.build_group/2` in the owner | same function at the router; group key in the candidate |
| Windows and buckets | `Bucketing` advance/prune by event time | unchanged |
| Cooldown | after resolve, a breach within `cooldown_seconds` records `:cooldown` history | unchanged; history id is a fire key |
| Incident rollover | gap greater than `cooldown_seconds` resolves and refires | unchanged; new `incident_seq` |
| Recovery (below threshold, or recovery match) | `handle_recovery` resolves | unchanged; recovery-match flag stamped at the router |
| Renotify | every `renotify_seconds` on a matching record | unchanged; ordinal fire key; operator-terminal alerts skipped by control input instead of a row read |
| Incident metadata | load and update the alert on every record | counters in state; one guarded write per commit |
| Seasonal and edge anomaly disposition | CNPG lookup in the owner | the same lookup at the router, stamped; suppress, escalate and pass-through unchanged |
| Anomaly-open subject guard | pending `RuleMatcher.event_candidate?/2` fix | the index anchor for anomaly-open rules |
| Stale-anomaly maintenance | ordered barrier work row, synchronous count | ordered marker per partition; summed receipts; same count contract |
| Log promotion | inline in `Logs`, ledger guards promotion alerts once | inline; promotion alerts idempotent by fire key; promotion rules matched through the index |
| Lifecycle signals | `lifecycle_pending_admissions` FIFO per series | partition order plus in-place publish retry |
| Metric conditions | violation tag, then counting | violation increment stamped at the router; counting unchanged |
| Rule edit | captured revision per work row | revision per candidate; immutable revisions |
| Rule disable or delete | durable cancellation of pending work | ordered marker; later candidates dropped and counted |
| Synthetic liveness check | awaits the persisted alert | unchanged (publishes through the router) |
| Notification routing | routing job in the owner transaction | same, unique by fire key |
| Fired OCSF event publication | DurablePublish outbox | unchanged, with a deterministic event id |
| Oversized occurrence | skipped as `record_too_large` | no byte budget exists, so nothing is skipped; a projection is bounded by the record's own size |

## Exactly-once and fire-once proof sketch

Notation: L_p is the ordered message log of partition p. (k, S_k) is the
committed checkpoint. F is the evaluator. E(m) is the set of fire keys F
emits for message m.

Invariants:

- **I1, single committer.** Every commit asserts the current lease epoch in
  its own transaction, and acquiring a lease increments the epoch. At most
  one epoch commits at any time, and a superseded owner commits nothing
  further.
- **I2, determinism.** F reads only S, the candidate and the immutable rule
  revision it names. External state reaches F only as ordered messages (D9),
  and F reads no wall clock and generates no random ids. Effect outcomes do
  not feed back into S (D5).
- **I3, idempotent effects.** Each effect is applied by insert-if-absent or
  a guarded update keyed by its fire key.
- **I4, effects before checkpoint.** A checkpoint at k commits only after the
  effects of every message up to k have committed. Effect commits run at batch
  end, and checkpoints run between batches.
- **I5, retention.** A message stays in the stream until a checkpoint at or
  past it commits (DiscardNew, no MaxAge, purge only up to k).
- **I6, dedupe continuity.** The candidate ids seen within H are part of the
  checkpoint (persisted slices).

No duplicate effects: take any two owners that process message j > k
starting from the same committed (k, S_k). By I2 and induction on the
messages between k and j, they reach the same state before j, so they emit
the same E(j). By I3, a second application of any fire key is a no-op. By
I1, an owner that lost its lease commits nothing new. So each fire key is
applied once, whichever owners ran and however often j was replayed.

No lost evaluation: by I5, every message after k is still in the stream. A
live replica eventually holds the lease after expiry, loads (k, S_k) and
applies every message after k in order. By I4, its effects commit before any
later checkpoint moves past it. A message's evaluation is therefore never
lost by crash, failover or rebalancing.

No double count: within H, a republished candidate has the same id and is
skipped (I6), including across failover. Beyond H, see Q5.

Equivalence: the committed effect set equals the effect set of one
uninterrupted run of F over L_p. Committed effects from a crashed owner are
the prefix that the replay recomputes.

What the proof does not cover: delivery to external notification channels
stays at-least-once, as today, behind `Notifications.Dedupe`. Gate G3 checks
I1-I6 by fault injection and property-based replay.

## HA and rebalancing

- **Unplanned failure.** The lease expires (15 s), the next preferred replica
  acquires it with epoch + 1, loads the checkpoint (about 1 s) and replays
  (under 2 s). Recovery takes about 20 s, during which candidates queue in
  the stream. A replica that cannot renew stops processing a safety margin
  before the TTL, measured with its monotonic clock. Correctness still rests
  on the fence (I1).
- **Planned handoff** (scale-out, scale-in, rolling deploy, SIGTERM): the
  owner checkpoints, then releases (`expires_at = now()`), and the preferred
  replica acquires immediately. The pause is about a checkpoint plus a load.
  At most 2 concurrent handoffs per replica, at least 10 s apart (settings).
  Termination grace must cover checkpointing every owned partition.
- **Split brain.** Two replicas that both believe they own p: the later
  acquisition has the higher epoch, and the earlier replica's next commit
  fails the fence, so it discards state and stops. Its uncommitted effects
  were never visible. Its committed effects are a prefix the new owner
  recomputes identically.
- **CNPG unavailable.** No commit can happen anywhere; owners stall and the
  streams absorb the backlog. **NATS unavailable.** Routers retry in place,
  sources lag, and collectors spool.
- **Hot keys.** One (rule, group) cannot be split without breaking its
  order. Its ceiling is one partition's throughput (at least 10,000/s, G2).
  Rule validation warns about ungrouped rules on high-rate signals, and
  per-partition lag makes a hot partition visible.
- **Stuck partition.** A partition whose owner cannot progress fills only its
  subject budget (per-subject limits with DiscardNew per subject). It turns
  health critical at 10 min. If it is never fixed it eventually stalls
  routing for everything, by design, because the alternative is losing its
  evaluations.
- **Re-partition** (changing P or the physical map): pause routing, so
  sources lag. Let every partition drain and checkpoint. Re-home group rows
  under the new hash and map version in one migration, bump
  `partition_map_version`, and resume. Evaluation pauses for minutes; nothing
  is lost. This is an operator procedure with a runbook, not an online
  operation.

## Migration (clean switch)

Release N ships the new schema, the router, the partitions, the new streams
and the cutover task, and deletes the inbox code. There is no runtime path
that evaluates through both designs.

1. **Rolling upgrade.** New replicas start routing candidates to the streams
   at once (durable, so nothing waits on the cutover). Their partition owners
   do not start until the cutover marker exists. New replicas do not run the
   `alerts` or `alert_recovery` Oban queues. Pre-cutover replicas keep
   admitting to and draining the inbox until they stop.
2. **Cutover task** (coordinator, release N). It waits until no pre-cutover
   core replica remains in the cluster, by capability, and no `alerts` job is
   executing. Then, in order:
   1. Convert every `stateful_alert_rule_states` row into partitioned group
      state (compute `partition`, set `incident_seq` and `renotify_ordinal`
      bases, keep open alert ids) and write checkpoint seq 0 per partition.
   2. Publish residual `alert_evaluation_work` rows, in (rule, position)
      order, as candidates on `alerts.candidates.v1.pNN.import`. They already
      carry their rule and revision.
   3. Route residual `lifecycle_pending_admissions` rows, in (series, seq)
      order, through the index onto the same import subjects.
   4. Publish an import-end marker per partition and write the cutover marker.
   Owners consume each partition's import subject to its end marker, then
   their live subject from the start. Residual work is therefore evaluated
   before anything routed after the upgrade began.
3. **Post-cutover migration** (release N). It refuses to run before the
   marker exists. It drops `alert_evaluation_work`, `alert_evaluation_lanes`,
   `alert_evaluation_receipts`, `stateful_evaluation_ledger` and
   `lifecycle_pending_admissions`, and deletes pending Oban jobs of the
   removed workers.
4. **Release N+1** removes the cutover task and the import subjects.

Removed code: `StatefulAlertEngine.Inbox`, `Owner`, `EvaluationWorker`,
`RecoveryWorker`, `Rollout`, `PeerReadiness`, `Completion` (replaced by
persisted-alert waits), `StatefulEvaluationLedger`, `MetricAlertAdmission`
(folded into the router), `LifecycleAdmissionDrainWorker`, the pending
admission code in `AnalyticsSignals`, the `alert_evaluation_limits` config,
the `alerts` and `alert_recovery` queues, and the Helm env
`SERVICERADAR_ALERT_EVALUATION_MODE`.

### What happens to `alert_evaluation_work` and `lifecycle_pending_admissions`

Both are drained into the candidate streams by the cutover task in their own
order, then dropped in the same release. No row is discarded: each residual
row becomes a candidate that is evaluated before newer input. The receipts
table is dropped too. Its replay role moves to candidate ids (D6) and
deterministic fire keys (D5), and its 7-day volume would be billions of rows
at the target. `stateful_alert_rule_states` is kept, in an extended form, as
the checkpoint store.

Rollback to a pre-cutover image after step 2 is not supported (Q9). Before
step 2, rolling back is an ordinary image rollback: no table has been dropped
and the inbox still holds its work.

## Observability

All metrics are published through JetStream and persisted by EventWriter.
Labels are bounded: partition number (at most P), physical stream, signal,
outcome, node. Rule ids are never metric labels.

- Per partition: lag in messages, lag age (now minus the publish time of the
  oldest unapplied message), applied/s, duplicates suppressed, dropped for a
  disabled rule, poison skipped, checkpoint age and duration, effect commit
  duration, owner node, epoch, takeover replay duration, active groups and
  state bytes.
- Router: records routed per signal, no-match ratio, candidates per signal,
  index version and compile time, in-place publish retry seconds, refusals by
  reason.
- Streams: fill percentage, bytes, messages, purge lag, per-subject
  refusals; source streams the same; collectors report refusals, spool depth
  and UDP drops.
- Per-rule cost (candidates/s, groups) is served on demand by an RPC to the
  owners and shown on the rule page, never as metric labels.
- Health: degraded at lag age over 60 s, any partition unowned over 30 s, or
  stream fill over 60%. Critical at lag age over 10 min, fill over 85%, poison
  skipped, or permanent effect failures. One health event per transition,
  from the coordinator.
- web-ng: an alert pipeline diagnostics page lists partitions with owner,
  lag, age and checkpoint age, and the stream fill gauges.

## Benchmark gates

Each gate has an explicit failure branch and reads artifacts, not job status.
Synthetic generators invent everything: device uids `sr:synthetic-dev-NNNNNN`,
hostnames `hostNNNNNN.example.com`, addresses from `2001:db8::/32` (the only
documentation range large enough for 100,000 distinct devices), and invented
rule and site names.

| Gate | Where | What | Fails when |
|---|---|---|---|
| G1 router | RBE, per PR (BazelCI) | 500 stateful + 200 promotion synthetic rules; 1M synthetic records | under 200k records/s per core, or p99 per-record cost over 20 us for logs/events or 5 us for metric points |
| G2 partition | RBE, per PR, real `nats-server` + srql-fixtures CNPG | one partition at 10,000 candidates/s for 10 min, 200k active groups | lag age p99 over 2 s, checkpoint commit p99 over 500 ms, or memory over 1.5 KB per group plus the dedupe ring |
| G3 exactly-once | RBE, per PR | fault injection: kill before effect commit, after effect commit and before checkpoint, mid checkpoint, mid replay; steal the lease; duplicate publishes inside and outside H; poison candidate; property-based replay from random checkpoints | any fire key missing or applied twice against the single-run oracle, any occurrence counted twice within H, or a stale epoch commit accepted |
| G4 fleet scale | in-cluster disposable namespace or the `workflows-lig` pool (Q7), nightly and before every release cut | 50k then 100k synthetic devices at the `capacity.md` sustained rates for 30 min, a 5 min burst at A10, then one core replica killed mid-burst | any discarded or terminally delivered message, any DLQ entry, any fired-alert set that differs from the generator's oracle (missing or duplicate), sustained lag age p99 over 30 s, alert fire latency p99 over 15 s, burst not drained to lag age under 5 s within 10 min, takeover over 30 s, core CPU over 70% or RSS over 75% of limit at sustained, alert-path CNPG writes over 5,000 rows/s, or more than 2 Stream Loads/s per table per replica |
| G5 semantics | RBE, per PR | golden effect traces for every row of the semantics table, captured from the current engine on synthetic scenarios before it is deleted, replayed through the partition evaluator | any trace difference |

G4 passes at 50k with at least 30% headroom before it runs at 100k. Its
report records the measured numbers that replace the estimates in
`capacity.md` 1.4.

## Risks / Trade-offs

- **Determinism is a discipline.** One wall-clock read or database read in a
  decision silently breaks the replay proof. Mitigation: the evaluator is a
  pure module with effects as data, G3 replays from random checkpoints, and a
  test asserts that the evaluator modules call no Repo, Ash or `DateTime.utc_now`.
- **A larger NATS footprint.** R3 candidate and source streams sized for
  outages need an `xlarge` profile at the design point. The render-time
  budget check covers the new streams.
- **A stuck partition eventually stalls ingestion.** That is the explicit
  price of never losing evaluations. It is critical in health long before.
- **Alert visibility can precede warehouse queryability** by up to the
  coalescing age.
- **Forward-only cutover.**
- **Scope.** This touches EventWriter, collectors, NATS profiles, web-ng and
  core. Tasks are ordered so that the alert path (sections 1-5) ships first
  and gives the measured numbers, and ingestion changes (section 6) follow
  behind the same gates.

## Open Questions

**Q1. Target rates and retention.** `capacity.md` A1-A16 are assumptions.
The ones that change the design: logs per device (A3), collector batching
(A8), rule counts and match rates (A11-A13), active groups (A14), and
StarRocks retention at the design point (0.5-1 PB for one year).
Options: (a) adopt the table as the design point; (b) supply measured or
contracted numbers. Recommendation: (a) for the gates now, then replace each
assumption with a measurement from a representative synthetic profile.
Confirm per-dataset retention before quoting storage.

**Q2. Partition count.** Options: 32, 64, 128. More partitions mean finer
rebalancing, more consumers and leases, and a smaller per-partition state.
Recommendation: **64**, which matches the edge-record map. It allows up to 64
owner replicas and keeps per-partition load around 625/s sustained.

**Q3. Checkpoint interval and replay window.** Options: 10 s (about 6,000
rows/s of checkpoint writes, under 1 s replay), 30 s (about 1,700 rows/s,
about 2 s replay), 60 s (about 900 rows/s, about 4 s replay; more coalescing).
Recommendation: **30 s with a 50,000-candidate cap**, so a burst cannot
stretch replay.

**Q4. Candidate stream outage budget.** Options: 30 min, 1 h, 4 h at the
sustained candidate rate (about 29, 58 and 230 GB per NATS server
uncompressed; about 4x less with S2). Recommendation: **1 h with S2**. Source
streams add 30 min behind it.

**Q5. Duplicate suppression horizon.** A redelivered source message can
republish candidates whose first publish succeeded. Without suppression, one
occurrence can be counted twice, and an alert can fire at N-1 real
occurrences. Options: (a) JetStream message-id dedupe only: no code, but
NATS memory of about 100 B per id (hundreds of MB at the target), and it
covers only the 2-minute default window; (b) the persisted evaluator ring
with H = 10 min (about 384 MB cluster-wide sustained, 640 KB/s of slice
writes); (c) none. The residual for (b) needs the candidate stream full and a
router crash at the same time, and costs at most one extra count per affected
group. Recommendation: **(b)**, with the NATS duplicate window at its
minimum.

**Q6. Raw log stateful rules (`signal: :log`).** They never run today:
`evaluate_logs/1` has no caller, but the seeded `burst_errors` rule uses
them. Options: (a) evaluate raw logs through the index and partitions. This
costs about 0.5 core at the design point and stores nothing extra; it
modifies "Stateful rules evaluate OCSF events" to include logs, a delta this
change adds once (a) is chosen. (b) Remove `signal: :log`, convert
`burst_errors` into a promotion rule plus an event rule, and default `signal`
to `:event`. Recommendation: **(a)**. At 100,000 logs/s, alerting by
promotion stores an extra event per matching log, which is the expensive
path.

**Q7. Where the fleet gate runs.** Options: (a) the `workflows-lig`
BuildBuddy pool; (b) an in-cluster disposable namespace with a real R3 NATS
cluster, StarRocks and CNPG; (c) both. Recommendation: **(b)** nightly and as
a required pre-release check, keeping G1-G3 and G5 on RBE per PR. A real R3
NATS cluster and a warehouse do not fit an RBE executor.

**Q8. Overflow at the edge.** DiscardNew source streams move overflow out of
JetStream to the publishers. Options: (a) accept: collectors spool and count;
UDP and trap sources, which cannot be retransmitted, are refused and counted
at the collector; (b) keep discard-old on source streams, which silently
evicts accepted data, as today. Recommendation: **(a)**.

**Q9. Forward-only cutover.** Options: (a) forward-only after the import;
(b) keep the old tables for one release and write a reverse importer for
rollback. Recommendation: **(a)**. A reverse importer is legacy machinery
whose only job is to undo the switch.
