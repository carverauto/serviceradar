# Design: Elastic, stream-backed alert evaluation at fleet scale

## Context

The rates this design must meet, the assumptions behind them and the audit of
today's path are in `capacity.md`. The short version: about 40,000 alert
candidates/s sustained and 100,000/s in a 5-minute burst at 100,000 devices,
against a current ceiling of about 90 evaluations/s cluster-wide. The five
worst breaking points are in `capacity.md` 2.3.

The same code must also run a demo or development install, which sees a few
candidates per second, with near-zero overhead. The user's direction
(2026-11-04) is to build for adjustable, dynamic scale rather than a fixed
large topology. Small installs run one candidate stream and grow by settings
and by adding core nodes, with no redeploy, no downtime and no loss.

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

- Meet the `capacity.md` targets with stated headroom. Scale out by adding
  core nodes and by splitting streams online.
- Run a small install (one stream, a few candidates/s) with near-zero
  overhead and no operator tuning.
- Never lose a signal or its evaluation to backpressure. Overload becomes lag.
- Fire each incident exactly once and count each occurrence exactly once,
  across crashes, failover, redelivery, rebalancing and resharding. Keep
  per-key order through all of them.
- Preserve every current rule behaviour (section "Semantics preservation"),
  and make `signal: :log` rules evaluate (they are inert today).
- Keep CNPG as the control plane only. Keep telemetry JetStream-first and
  StarRocks-only when enabled.
- Remove the inbox, ledger and pending-admission machinery outright.

Non-Goals:

- A new rule language, new rule features, or multi-rule correlation.
- Moving per-series anomaly detection back to core. That stays at the edge
  (`move-anomaly-detection-to-edge`).
- Flow alerting. Flows stay StarRocks-only and are not evaluated
  (`scale-netflow-ingest-isolation` owns flow ingest).
- An edge-resident rule engine. Alert availability remains core availability
  (`docs/docs/architecture.md`).
- Silent automatic resharding (D12).
- Multitenancy. Everything is scoped to the one deployment.

## Architecture

```
 collectors / gateways / agents
   | batched publish to block-partitioned subjects (logs.v1.bNNN.*, events.v1.bNNN.*, ...)
   v
 JetStream telemetry streams (R3, DiscardNew; 1 per signal on small installs, split by setting)
   | one durable per source block; each source block leased to one replica
   v
 EventWriter router (single writer per source block)
   decode -> normalize -> promote
     |-- store: warehouse coalescer (StarRocks) or CNPG ------------+
     |-- route: compiled rule index -> candidates                   |
     |      publish to alerts.candidates.v1.bNNN.vNNNN, serial per key |
     +-- ack source message only after BOTH complete <--------------+
   v
 JetStream candidate streams ALERT_CANDIDATES_V1_*
   (1 on small installs; each stream owns a set of blocks; Limits, DiscardNew,
    no MaxAge, purged behind checkpoints)
   | one ordered consumer per owner per stream, filtered to the owner's blocks
   v
 Block owner (one per core node; leases blocks)
   dedupe ring -> deterministic state machine (ETS) -> effects as data
     |-- effect commit (CNPG, fenced by block epochs, idempotent by fire key)
     |-- checkpoint commit (CNPG, fenced: dirty groups + dedupe slices + block seqs)
     +-- purge each block's subjects up to its committed checkpoint
   v
 alerts, history, notification routing jobs, DurablePublish outbox
```

Three layers keep routing stable while capacity changes:

| Layer | Size | Changes | Unit of |
|---|---|---|---|
| Virtual partition | 1,024, fixed forever by hash version `v1` | never | key hashing; group state and dedupe rows carry it |
| Block | 128 blocks of 8 consecutive virtual partitions (layout `v1`) | only by an offline re-layout, which needs no rehash | subject token, stream assignment, ownership lease, checkpoint |
| Physical stream and owner | 1 to 128 streams; 1 owner process per core node per stream | online, by settings and node count | NATS placement, CPU |

Control inputs (rule disable/delete, stale-anomaly maintenance, operator
alert actions, block moves, cutover import segment ends) are messages on the same
block subjects, so they are ordered with the candidates they affect.

## Decisions

### D1: Compiled rule index at the router (direction 1: adopt)

Each EventWriter replica compiles the active stateful rules (event, metric
and log) and promotion rules into an immutable index per signal:

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

Raw log records route through the same index to `signal: :log` rules
(resolved Q6). Today `StatefulAlertEngine.evaluate_logs/1` has no caller,
so the seeded `burst_errors` rule never runs. After this change it does,
without promoting and storing an extra event per matching log.

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
read at route time). It stamps all of them into the candidate. The
evaluator then never reads an external store to decide (D5).

Rejected: matching inside the evaluator against every rule. That puts every
record on the candidate stream, which is today's cost moved to NATS.

### D2: A fixed key space with a dynamic stream map (directions 2 and 3: adopt, adapted to elastic)

Routing never changes. A candidate's virtual partition is
`vp = H_v1(rule_id, group_key) mod 1024`, and its block is `b = vp div 8`. It
is published on `alerts.candidates.v1.b<b>.v<vp>`. The hash function and the
1,024 size are frozen by the version tag, so a key's subject is the same for
the life of the installation. The virtual partition count is not a runtime
setting. Changing it would be a versioned-hash migration (`v2`), with its own
cutover, and is out of scope for this change.

What changes is which physical stream holds a block. `alert_stream_map` in
CNPG assigns every one of the 128 blocks to exactly one physical stream,
under a monotonically increasing map generation. Each stream's subject list
is the wildcards of its blocks (`alerts.candidates.v1.b017.*`, ...), at most
128 entries. No subject is ever bound to two streams: NATS refuses
overlapping stream subjects, and the move protocol (D12) relies on that.

Defaults are sized for a small install: one stream
(`ALERT_CANDIDATES_V1_S0`) holding all 128 blocks. The design point
(`capacity.md` 1.4) runs 4 streams. The ceiling is 128 streams of one block
each. Each physical stream is a separate Raft group, so streams spread
leaders across NATS servers.

Stream shape: file storage, R3 (capped to `nats.replicas`), S2 compression,
Limits retention, DiscardNew, `MaxAge` 0, finite `max_bytes` from a CNPG
runtime setting whose code default is derived from the active JetStream
profile: 1 h of stored, S2-compressed bytes at the profile's sustained
candidate rate (resolved Q4). Candidates are sized at p99 including the full
projected payload; at the design point that is about 180 GB before
compression and about 90 GB stored at a conservative 2:1 S2 ratio, which
gate G4 measures and confirms (`capacity.md` 1.3-1.4). The duplicate
window at its minimum, because deduplication belongs to the evaluator (D6).
Owners delete consumed messages by purging each block's subjects up to that
block's committed checkpoint (a purge filtered to `...b<b>.*`), so an idle
block never holds back another block's purge. Nothing ages out unprocessed.

Per-rule CNPG inbox rows are gone. The candidate is a protobuf
`serviceradar.alerts.v1.Candidate`: rule id and revision, virtual partition,
kind (match, recovery match or control), group key and values, event time,
signal, source key and stored-record reference, the stamped router outputs
from D1, and the evaluation projection (D8). Its candidate id is a 128-bit
hash of (rule id, source key, kind).

Rejected: a fixed 64-partition layout. Small installs would pay for 64 of
everything, and growing past it would mean rehashing every key. Rejected:
evaluating directly on device-partitioned source streams. Rules group by
gateway, by service or globally, so one rule's groups span every source
partition, and counts would need a cross-partition merge with coordinated
firing.

### D3: Block ownership by fenced CNPG leases (direction 3: adopt)

`platform.alert_block_leases` holds one row per block: owner node, `epoch`
(bigint fencing token), `expires_at`. Leases are taken and renewed by
compare-and-set using database time (`now()`), never node clocks. Acquiring a
block increments its epoch. A node renews all its blocks in one statement
every 5 s, with a 15 s TTL (CNPG runtime settings).

Every effect commit and checkpoint commit runs in one transaction that first
asserts, with a row lock, that every block it touches still has the
committing node's (block, epoch) pair and has not expired. A stale owner's
commit therefore fails, and it stops processing those blocks. Rows, not
session advisory locks, carry ownership, so leases work through the
transaction-pooled PgBouncer path. Session locks leak there.

Placement: blocks are spread over live core replicas that have repository
access and advertise `alert-partitions-v1`, by rendezvous hashing of the
block id. The `owner_placement` setting (default `rendezvous`) also accepts
an explicit pin list. Each node runs one owner process per physical stream
it holds blocks in. That process reads one ordered consumer whose filter is
its blocks' wildcards. On a small install that is one consumer per node and
128 lease rows in total.

Adding a core node moves about 1/N of the blocks to it through planned
handoffs (see "HA and rebalancing"). Owner rebalancing is automatic, because
it is the same fenced path as failover.

Rejected: Horde/ProcessRegistry ownership, which has no fencing token that a
database commit can check (the #4511 loss path). Rejected: JetStream KV
leases, because the fence must be checked in the same transaction as the
alert write, and that transaction is in CNPG.

### D4: Deterministic in-memory state with incremental checkpoints (direction 4: adopt)

Each owner keeps ETS state keyed by `{rule_id, group_key}`. The value is
today's snapshot shape (bucket counts, current bucket, last seen, last fired,
last notification, cooldown, alert id, first seen, diagnostics) plus five
fields: the virtual partition, `incident_seq` and `renotify_ordinal` for fire
keys (D5), `operator_terminal` (D9), and the applied sequence. Each block
also keeps an `applied_count`, incremented once per message it applies
(candidate, control or import), checkpointed with the block and never reset
by a stream move, a map generation change or the cutover import. A group's
`last_seen_at` never moves backward: an applied candidate whose event time
precedes it is counted in its bucket and leaves `last_seen_at` unchanged.
Per-key order already holds by construction (D6); this guard is defense in
depth for one group fed by several sources, whose candidates are ordered by
arrival at the stream rather than by event time. The existing
`StateMachine`, `Bucketing`, `Diagnostics`, `MetricCondition` and
`EdgeAnomalyDisposition` decisions are reused. They are refactored so that
they return effects as data instead of performing Ash writes (D5).

A group whose window is empty, with no open incident and no running cooldown,
is evicted. It equals the default state, so dropping it changes no outcome.
This bounds memory to active groups. An idle install holds almost nothing.

Checkpoint: every `checkpoint_interval_ms` or `checkpoint_max_candidates`,
whichever comes first, and on handoff. Code defaults are sized for a small
install: 10 s and 10,000 candidates, so a demo replays a few seconds at most.
Large installs raise them; the design point recommends 30 s and 50,000
(`capacity.md` 1.4). An idle owner skips checkpoints that would change
nothing, so a quiet install writes only lease renewals. One fenced
transaction:

1. upserts the dirty groups into `stateful_alert_rule_states`, which gains a
   `virtual_partition` column, and deletes evicted ones;
2. inserts the closed dedupe slices (D6) and deletes slices older than the
   horizon;
3. advances `alert_block_checkpoints(block, stream, seq, epoch)` for the
   blocks that moved. A block's `seq` is the stream sequence of the last of
   that block's own messages the owner applied.

Writes scale with dirty groups, not total state. Rejected: a whole-partition
state blob per checkpoint. Its write volume grows with total state rather
than with change, and the existing table, which the UI reads, would go stale.

Recovery loads the blocks' rows and slices and starts the ordered consumer at
the lowest checkpoint sequence among them. It skips any message at or below
its own block's checkpoint, so blocks that join at different positions are
handled exactly.

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
- incident metadata updates carry the block's `applied_count` at the
  message that produced them as the evaluation position, and apply only when
  it is greater than the stored value (`alerts.evaluation_position`). Stream
  sequences and map generations are not part of it, because they restart or
  change across a block move and the cutover import while `applied_count`
  only grows.

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
recovers the affected blocks from their checkpoint and replays: one
crash-only path, tested by G3. A permanent per-effect failure (a constraint
or validation error) rolls back only that effect to a savepoint and is
written, keyed by its fire key, to `alert_effect_failures` with diagnostics
in the same fenced effect transaction, which commits the batch's other
effects. It raises a health signal. The in-memory state keeps the planned
state F produced, including the planned alert id, and the next checkpoint
commits it as usual. The applier treats an effect whose fire key already has
a recorded permanent failure as a no-op, so a replay that re-emits it neither
retries it nor stalls the block, and F stays pure. Today, a failed create
leaves the snapshot without an alert id and re-fires on every match without
paging anyone (the `resolved_device_uid/1` comment). That loop goes away.

Content may depend on external reads, for example device attribution at
fire time. The first committed write of a fire key wins and a replay is a
no-op, so content reads cannot cause duplicates.

Promotion alerts created by `LogPromotion` become idempotent by
UUIDv5(promotion_rule_id, event_id) with insert-if-absent. That is the only
thing the per-event ledger guarded for them.

### D6: Backpressure is lag, never loss (direction 5: adopt)

Consumption: owners read with ordered consumers: an ephemeral pull consumer
with `AckPolicy none`, a start sequence from the checkpoint, filter subjects
of the owner's blocks, recreated from the last applied sequence on any gap
or ownership change. No acknowledgement, no `ack_wait`, no `max_deliver`. A
slow or stopped owner can never cause a redelivery storm or a terminal drop.
Retention is the explicit purge behind checkpoints (D2).

Duplicates (resolved Q5): a source redelivery can republish a candidate whose
earlier publish succeeded. The owner keeps a ring of 128-bit candidate ids
for the duplicate horizon H (default 10 min) in closed 10 s slices per block.
A repeated id is skipped and counted. Closed slices are persisted with the
checkpoint and move with their block, so a new owner, including one that
takes a block mid-reshard, suppresses duplicates exactly as the old one
would have. Ids are 128-bit because a collision silently drops a real
occurrence. The one residual case needs a candidate stream full for longer
than H together with a router crash; it costs at most one extra count per
affected group and is counted in health.

Per-key order holds by construction. Each block of an alert-feeding source
stream is leased, with the D3 primitive, to one EventWriter replica, which
consumes it through that block's own durable and is the only router for the
block's sources (D10). Within a replica, one block's messages pass through
one batcher at a time, in stream order. The router publishes candidates
pipelined across keys but serially within a key: the next candidate for a
(rule, group) key is published only after the previous candidate for that
key has its PubAck. A key's candidates from one source therefore reach the
candidate stream in source order, and two sources feeding one key are ordered
by their arrival at the stream, which every replay sees identically.

Publishing: a refusal (stream full, NATS unavailable, timeout, no stream for
the subject during a block move) is retried in place, with capped backoff
(`publish_retry_backoff_max_ms`) and no attempt limit. A retried candidate
keeps its place at the head of its key, so later candidates of that key wait
behind it and retries keep per-key order. The router sends `+WPI` progress
acknowledgements on the source messages so they are not redelivered while it
waits, and it never NAKs for a publish failure. A health event is raised
after 30 s of continuous retry.

Router crash: a source message is acknowledged only after its candidates
have PubAcks, and a later candidate of a key is published only after the
earlier one's PubAck. A crash can therefore leave a key's earlier candidate
stored and its later one unpublished, never the reverse. The replica that
takes the source block over processes the block's unacknowledged messages in
stream-sequence order before newer ones. The republished earlier candidate
is suppressed by its candidate id, and the later one is stored after it.

When a stream is full, publishers are refused; accepted messages are never
evicted. The chain of buffers is in `capacity.md` 1.5: candidate streams,
then source-stream lag, then refusal at the collector (resolved Q8).

Poison: a candidate that crashes the pure evaluator at the same sequence on
three consecutive attempts is copied to `ALERT_CANDIDATES_DLQ_V1` (DiscardNew,
no MaxAge) with its error. The owner awaits the DLQ PubAck and retries a
refused copy in place, with capped backoff and no attempt limit, without
advancing that block's checkpoint; a full DLQ therefore stalls the block as
lag rather than losing the audit entry. Once the copy is acknowledged, its
sequence is recorded as a skipped disposition in the block checkpoint, health
turns critical, and the block continues. The
underlying record is already stored, and redrive replays the DLQ entry
through the evaluator after a fix. This is the audited terminal disposition,
not a silent drop. Only exceptions inside F qualify; store errors are
transient by definition.

### D7: CNPG holds only lifecycle, checkpoints, leases and rule config (direction 6: adopt)

The new CNPG tables are `alert_block_leases`, `alert_block_checkpoints`,
`alert_block_dedupe_slices`, `alert_stream_map` (with its move journal),
`alert_effect_failures`, `alert_maintenance_receipts`, the release-N
`alert_cutover_progress`, an immutable
`stateful_alert_rule_revisions`, and `AlertEvaluationSettings`. Existing
tables kept: `stateful_alert_rule_states` (now the incremental checkpoint),
`stateful_alert_rule_histories`, `alerts` (adds `fire_key` unique and
`evaluation_position`), and the rule resources. Telemetry about the pipeline
goes through JetStream and EventWriter. None is written directly to CNPG or
StarRocks.

### D8: The candidate carries an evaluation projection, not the record (adapted)

Today's work row embeds the whole record and the whole rule. The candidate
instead carries every field that any compiled rule or the alert builder
reads. That is the union of match, group, template and diagnostic field
references, computed when the index is compiled, plus a fixed core
(identity, time, severity, device, subject, message, observables). It also
carries a reference to the stored record. Each projected value is carried
whole. Fields that no rule reads are not copied, and the stored record keeps
them. A candidate is therefore as large as the fields it carries: stream
sizes use the p99 candidate size per signal, 12.7 KB for an event candidate
such as a Falco trace (`capacity.md` 1.3), not a mean envelope. That is projection, not truncation. A rule edit that references a new
field recompiles the projection, and candidates routed afterwards carry it.

The rule itself is referenced by (rule_id, revision). Revisions are
immutable rows, cached by owners, so a replay evaluates exactly the revision
that was routed.

### D9: Ordered control inputs replace every external read a decision made

Today some decisions read mutable rows at evaluation time: whether the rule
is still enabled, the alert's current status (renotify and recovery treat an
operator-resolved alert as terminal), and episode liveness for stale
resolution. A replay could decide differently if those rows changed in
between. Each becomes an ordered message on the affected blocks, published
through the DurablePublish outbox in the transaction that made the change:

- **Rule disabled or deleted:** a marker to every block. Later candidates of
  that rule are dropped and counted, which matches today's durable
  cancellation. Delete also clears the rule's groups. Edits need no marker,
  because candidates carry their revision.
- **Operator alert action** (resolve, suppress, any status the evaluator
  reads): a message to the alert's virtual partition, computed from the
  incident rule and group key in its metadata. The group records
  `operator_terminal`. As today, it is not renotified and does not re-fire
  until the group recovers.
- **Stale-anomaly maintenance:** `resolve_stale_anomalies/4` publishes a
  maintenance marker carrying `cutoff`, `now` and an immutable live-series
  snapshot id to every block, then awaits one `alert_maintenance_receipts` row
  per block with a bounded timeout. It returns their summed resolved count,
  which keeps today's synchronous contract.
- **Block move and cutover import segment ends:** see D12 and Migration.

The evaluator uses no wall clock. Time comes from event time or from the
`now` a control message carries.

### D10: Elastic ingestion (direction 7)

Findings and changes, keyed to `capacity.md` S1-S5 and S13:

- **Source streams (S2).** Split the shared `events` stream by signal:
  `LOGS_V1`, `EVENTS_V1`, `OTEL_V1`, and the existing `metrics`. Subjects
  carry a block of the same 128-block layout, hashed from the source device
  or address (`logs.v1.b<b>.<source>`). Each signal has its own dynamic block
  map, with `telemetry_stream_count` per signal as a setting. The default is
  1 stream per signal on small installs and 4 at the design point. Streams are
  R3 and DiscardNew, with `max_bytes` from a CNPG runtime setting whose code
  default is derived from the active JetStream profile (a 30-minute outage
  window). A block moves between telemetry streams with the same protocol as
  candidate streams (D12), so a source's records keep their order through a
  split.
- **Source blocks have one router (per-key order).** Each block of an
  alert-feeding stream is leased to one EventWriter replica with the D3
  primitive (`telemetry_block_leases`, rendezvous placement, planned
  handoffs). The holder consumes the block through that block's own durable
  (filter `logs.v1.b<b>.>`), so no two replicas route one source. A new
  holder processes the block's unacknowledged messages in stream-sequence
  order before newer ones (D6).
- **EventWriter batching (S3).** Batchers per signal get configurable
  concurrency (default `System.schedulers_online/0 / 2`). Messages are
  partitioned to batchers by source block, so concurrency comes from distinct
  blocks and one block's messages are batched in stream order. Batch size and
  timeout become CNPG runtime settings with code defaults. Pull batch and
  `max_ack_pending` per block durable are sized from the coalescing window
  below.
- **Warehouse loads (S4).** A per-dataset coalescer per replica gathers rows
  from many Broadway batches. It flushes at 50,000 rows, 32 MB or 5 s, and
  acknowledges the contributing source messages only after the load succeeds,
  so the existing Stream Load knobs finally shape loads. Loads per table per
  replica stay at about 1/s or less at the design point; a small install
  flushes on age.
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
  refused is visible (resolved Q8).
- **Single-writer processors (S13).** `ANALYTICS_PREDICTIONS`, the causal
  streams, `K8S_INVENTORY` and `TRIVY` move from the coordinator to the same
  leased-block primitive. They partition by finding/series, prefix or report
  key, so per-key order holds and they scale out. This supersedes Decision 3
  of `scale-event-writer-across-core-replicas` for those streams. Lifecycle
  transitions keep per-series FIFO through block order plus in-place publish
  retry, which is what `lifecycle_pending_admissions` provided.

### D11: Runtime settings in CNPG, defaults sized small

`AlertEvaluationSettings` is a singleton row; every field has a code default
sized for a small install:

| Setting | Code default (small) | Design-point recommendation |
|---|---|---|
| `candidate_stream_count` | 1 | 4 |
| `owner_placement` | `rendezvous` over capable core nodes | `rendezvous` |
| `checkpoint_interval_ms` | 10,000 | 30,000 |
| `checkpoint_max_candidates` | 10,000 | 50,000 |
| `lease_ttl_ms` / `lease_renew_ms` | 15,000 / 5,000 | same |
| `batch_max_candidates` / `batch_max_wait_ms` | 500 / 50 | same |
| `dedupe_horizon_s` | 600 | 600 |
| `max_concurrent_moves` (handoffs and block moves) | 2 | 4 |
| `publish_retry_backoff_max_ms` (publish attempts are never capped) | 5,000 | same |
| lag degraded / critical thresholds | 60 s / 600 s | same |
| `unowned_block_grace_s` (degraded) | 30 | 30 |
| stream fill degraded / critical bounds | 60% / 85% | same |
| `move_stall_critical_s` | 600 | 600 |
| candidate stream and alert DLQ `max_bytes` | derived from the active JetStream profile (table below) | derived from `xlarge` (1 h budget) |
| `auto_reshard` | `false` | `false` (D12) |

EventWriter batching, coalescer limits, `telemetry_stream_count` per signal
and the telemetry stream and telemetry DLQ `max_bytes` join the existing
EventWriter runtime settings with the same rule. Every stream byte size is a
CNPG setting whose code default is derived from the active JetStream profile.
Helm supplies only the NATS server volume and `max_file_store`
(`jetstream-storage-budget`), plus a new `xlarge` profile. A size setting
that would exceed the JetStream file store is rejected when saved.

Profile-derived defaults. Each profile has a planning candidate rate. Its
candidate default is 1 h of that rate at the `capacity.md` 1.3 p99 mix
(about 1.25 KB per candidate, 50 MB/s at 40,000/s), stored at the
conservative 2:1 S2 ratio, rounded up. The candidate streams, the alert DLQ,
the signal-separated telemetry streams and the telemetry DLQ replace the
profile's existing `events` and `metrics` allocations, all R3, so their
defaults are carved from those allocations and every profile's render-time
need is unchanged:

| Profile | `max_file_store` | Planning rate | Candidate streams (total) | Alert DLQ | Telemetry streams and DLQ (rest of `events` + `metrics`) |
|---|---|---|---|---|---|
| `tenant-2g` | 2G | 1/s | 4 MiB | 1 MiB | 315 MiB |
| `small` | 36G | 100/s (covers a demo Falco burst) | 256 MiB | 64 MiB | 2.6875 GiB |
| `medium` | 100G | 200/s | 512 MiB | 128 MiB | 9.375 GiB |
| `large` | 500G | 2,000/s | 4.5 GiB | 512 MiB | 35 GiB |
| `xlarge` | 2000G | 40,000/s | 84 GiB (about 90 GB) | 4 GiB | sized by task 3.2 for the 30-minute window |

With several candidate streams, the total is divided evenly. G4 replaces the
2:1 ratio with the measured one.
`SERVICERADAR_ALERT_EVALUATION_MODE` and its Helm rendering are removed.

### D12: Online block moves for split and merge, with health recommendations

A **block move** is the only resharding primitive. Split, merge and
rebalancing between streams are sequences of moves. The coordinator runs a
move when the setting `candidate_stream_count` (or `telemetry_stream_count`)
differs from the current map, choosing blocks so that the streams hold
contiguous, even ranges. Moves are journalled in `alert_stream_map` and
resumable after a coordinator failover. At most `max_concurrent_moves` run at
once.

Moving block b from stream A to stream B:

1. **Prepare.** Create or reconcile B, without b's subjects. Write the move
   to the journal (state `prepared`, generation g+1).
2. **Cut.** Update A's subject list to remove `...b<b>.*`. From this moment
   the A stream leader refuses every publish to b's subjects, because no
   stream binds them. After the update, read the greatest stored sequence
   among b's own subjects in A, or 0 when A holds none; that is `cut_seq`.
   Every candidate for b ever stored in A has a sequence at or below
   `cut_seq`, and messages of other blocks do not affect it. Record `cut_seq`
   in the journal (state `cut`).
3. **Rebind.** Update B to add `...b<b>.*` and record the journal state
   `bound`. Publishes for b that were refused between steps 2 and 3 were
   retried in place by the router (D6) and now land in B, after every b
   candidate already stored in A. Per-key serial publishing keeps each key's
   order across the gap.
4. **Drain and switch.** The owner of b keeps applying b's messages from A up
   to `cut_seq`. Only once every b message at or below `cut_seq` is inside
   its committed checkpoint for b (immediately when `cut_seq` is 0) does it
   start consuming b from B's first sequence. The checkpoint row records the
   switch (stream B, sequence 0), atomically with the last A position.
   Journal state `switched`.
5. **Reclaim.** b's remaining messages in A, all at or below `cut_seq` and
   applied, are purged by b's per-block purge. A stream with no blocks left
   is deleted once it holds no messages.

Ownership is unaffected: a move changes where b's messages are, not who
evaluates b. A block move and an owner handoff may overlap; they compose
because both are recorded in b's checkpoint row and fenced by b's epoch.

Why it is exactly-once and order-preserving:

- No subject is ever bound to two streams (NATS enforces it), so b's history
  is a prefix in A (sequences up to `cut_seq`) followed by a suffix in B. The
  owner applies the prefix before the suffix (step 4), so per-key order holds.
- Nothing is lost. Publishes during the gap are refused, never dropped, and
  retried. A's b messages are not purged until b's checkpoint covers them
  (I5).
- A refused publish that A had in fact stored before the cut, with its PubAck
  lost, is retried into B and arrives twice. It has the same candidate id and
  the block's dedupe ring, which spans both streams, suppresses it (I6).
- A crash at any step resumes from the journal. Steps 2 and 3 are idempotent
  stream updates; `cut_seq` is read once and stored; step 4 is driven by b's
  checkpoint.

Telemetry streams use the same five steps, with the same per-block
`cut_seq`. Their "owner" is the replica holding the source block: it keeps
consuming b's durable on A until that durable's ack floor reaches `cut_seq`,
and only then creates and consumes b's durable on B. A source's records
therefore keep their order through a split.

**Health recommendations, not silent auto-resharding** (the user's question
"recommend which"). The coordinator compares each stream's sustained message
and byte rate, Raft leader load and fill against per-stream capacity bounds
(defaults from G4 measurements). It compares each owner's lag age and CPU
against node budgets. Health then reports `split recommended: stream S0
(sustained 85% of per-stream bound)`, `add core capacity: owners CPU-bound
with lag rising`, or `merge possible`, each with the setting value to apply.
**Recommendation: operator-triggered moves by default (`auto_reshard =
false`), with an opt-in automatic mode.** The move protocol is safe to run
automatically. The decision is not: a split needs NATS disk and placement
headroom that the coordinator cannot reserve. A split on a full NATS cluster
turns a throughput problem into a placement outage, as happened with the
`mtr_results` placement failure. With `auto_reshard = true` the coordinator
applies its own recommendation only after a placement dry run succeeds and
the trend has held for the hysteresis window (15 min). G6 proves the protocol
either way. Owner rebalancing after adding a node is always automatic.

## Semantics preservation

| Feature | Today | After |
|---|---|---|
| Threshold N in window T | bucket counts by event time per group | same functions, in block state |
| Grouping (`group_by`) | `Record.build_group/2` in the owner | same function at the router; group key in the candidate |
| Windows and buckets | `Bucketing` advance/prune by event time | unchanged |
| Cooldown | after resolve, a breach within `cooldown_seconds` records `:cooldown` history | unchanged; history id is a fire key |
| Incident rollover | gap greater than `cooldown_seconds` resolves and refires | unchanged; new `incident_seq`; `last_seen_at` never moves backward (defense in depth, D4) |
| Recovery (below threshold, or recovery match) | `handle_recovery` resolves | unchanged; recovery-match flag stamped at the router |
| Renotify | every `renotify_seconds` on a matching record | unchanged; ordinal fire key; operator-terminal alerts skipped by control input instead of a row read |
| Incident metadata | load and update the alert on every record | counters in state; one guarded write per commit |
| Seasonal and edge anomaly disposition | CNPG lookup in the owner | the same lookup at the router, stamped; suppress, escalate and pass-through unchanged |
| Anomaly-open subject guard | pending `RuleMatcher.event_candidate?/2` fix | the index anchor for anomaly-open rules |
| Stale-anomaly maintenance | ordered barrier work row, synchronous count | ordered marker per block; summed receipts; same count contract |
| Log promotion | inline in `Logs`, ledger guards promotion alerts once | inline; promotion alerts idempotent by fire key; promotion rules matched through the index |
| `signal: :log` rules | never evaluated (no caller) | evaluated through the index on stored log records |
| Lifecycle signals | `lifecycle_pending_admissions` FIFO per series | block order plus in-place publish retry |
| Metric conditions | violation tag, then counting | violation increment stamped at the router; counting unchanged |
| Rule edit | captured revision per work row | revision per candidate; immutable revisions |
| Rule disable or delete | durable cancellation of pending work | ordered marker; later candidates dropped and counted |
| Synthetic liveness check | awaits the persisted alert | unchanged (publishes through the router) |
| Notification routing | routing job in the owner transaction | same, unique by fire key |
| Fired OCSF event publication | DurablePublish outbox | unchanged, with a deterministic event id |
| Oversized occurrence | skipped as `record_too_large` | no byte budget exists, so nothing is skipped; a projection is bounded by the record's own size |

## Exactly-once and fire-once proof sketch

Notation: L_b is the ordered message history of block b. During a move it is
a prefix in stream A up to `cut_seq` followed by a suffix in stream B. (k,
S_k) is b's committed checkpoint, a position in L_b plus the state of b's
groups. F is the evaluator. E(m) is the set of fire keys F emits for message
m.

Invariants:

- **I1, single committer per block.** Every commit asserts the current
  (block, epoch) of every block it touches, in its own transaction, and
  acquiring a block increments its epoch. At most one epoch commits for b at
  any time, and a superseded owner commits nothing further for b.
- **I2, determinism.** F reads only S, the candidate and the immutable rule
  revision it names. External state reaches F only as ordered messages (D9),
  and F reads no wall clock and generates no random ids. Effect outcomes do
  not feed back into S (D5).
- **I3, idempotent effects.** Each effect is applied by insert-if-absent or
  a guarded update keyed by its fire key, and an effect whose fire key has a
  recorded permanent failure is a no-op.
- **I4, effects before checkpoint.** A checkpoint at k commits only after the
  effects of every message of b up to k have committed. Effect commits run at
  batch end, and checkpoints run between batches.
- **I5, retention.** A message stays in its stream until a checkpoint of its
  block at or past it commits (DiscardNew, no MaxAge, each block's subjects
  purged only up to that block's committed checkpoint).
- **I6, dedupe continuity.** The candidate ids seen within H are part of the
  block's checkpoint (persisted slices), across owners and across streams.
- **I7, single binding.** A block's subjects are bound to at most one stream
  at a time, and a move switches consumption only after b's checkpoint
  covers every b message at or below `cut_seq`, the greatest sequence of b's
  own messages in the source stream (D12). L_b is therefore one well-defined
  sequence.
- **I8, per-key publish order.** Each source block has one router (a fenced
  lease), which publishes a key's candidates serially, each after the
  previous one's PubAck, and retries in place at the head of the key. A
  router crash can leave only a suffix of a key's candidates unpublished,
  and the next holder republishes in source order (D6). Within L_b, a key's
  candidates from one source are therefore in source order.

No duplicate effects: take any two owners that process message j after k in
L_b, starting from the same committed (k, S_k). By I2 and induction on the
messages between k and j, they reach the same state before j, so they emit
the same E(j). By I3, a second application of any fire key is a no-op. By
I1, an owner that lost b commits nothing new for b. So each fire key is
applied once, whichever owners ran, however often j was replayed, and
whichever stream held j.

No lost evaluation: by I5 and I7, every message of L_b after k is still in
its stream. A live replica eventually holds b after lease expiry, loads
(k, S_k) and applies L_b after k in order. By I4, its effects commit before
any later checkpoint moves past it.

No double count: within H, a republished candidate has the same id and is
skipped (I6), including across failover and across a move.

Equivalence: the committed effect set equals the effect set of one
uninterrupted run of F over L_b, per block. Groups never span blocks, so the
union over blocks is the whole system's effect set.

What the proof does not cover: delivery to external notification channels
stays at-least-once, as today, behind `Notifications.Dedupe`. Gates G3 and G6
check I1-I7 by fault injection and property-based replay.

## HA and rebalancing

- **Unplanned failure.** A block's lease expires (15 s), the next preferred
  replica acquires it with epoch + 1, loads the checkpoint and replays. A
  small install replays at most 10 s of input; the design point under 2 s.
  A replica that cannot renew stops processing a safety margin before the
  TTL, measured with its monotonic clock. Correctness still rests on the
  fence (I1).
- **Planned handoff** (node added or removed, rolling deploy, SIGTERM): the
  owner checkpoints the block, then releases it (`expires_at = now()`), and
  the preferred replica acquires it immediately. Handoffs are rate-limited by
  `max_concurrent_moves`. Termination grace must cover checkpointing every
  owned block.
- **Scale-out.** A new core node advertises the capability, rendezvous
  preference moves about 1/N of the blocks to it, and each move is a planned
  handoff. No setting change is needed.
- **Split brain.** Two replicas that both believe they own b: the later
  acquisition has the higher epoch, and the earlier replica's next commit
  fails the fence, so it discards b's state and stops. Its committed effects
  are a prefix the new owner recomputes identically.
- **CNPG unavailable.** No commit can happen anywhere; owners stall and the
  streams absorb the backlog. **NATS unavailable.** Routers retry in place,
  sources lag, and collectors spool.
- **Hot keys.** One (rule, group) cannot be split without breaking its
  order. Its ceiling is one owner's single-key throughput (at least 10,000/s,
  G2). Rule validation warns about ungrouped rules on high-rate signals, and
  per-block lag makes a hot block visible.
- **Stuck block.** A block whose owner cannot progress keeps its own messages
  unpurged. It turns health critical at 10 min. If it is never fixed it
  eventually fills its stream and stalls routing, by design, because the
  alternative is losing its evaluations.
- **Re-layout** (changing the 128-block layout or the hash version) is the
  one offline operation: drain, re-home group rows, bump the version. It
  should never be needed, because 128 blocks already allow 128 streams and
  128 owners.

## Migration (clean switch)

Release N ships the new schema, the router, the owners, one candidate stream
and the cutover task, and deletes the inbox code. There is no runtime path
that evaluates through both designs.

1. **Rolling upgrade.** The first upgraded replica creates the release-N
   import stream `ALERT_IMPORT_V1` bound to `alerts.import.v1.>` (R3,
   Limits, DiscardNew, no MaxAge, idempotent create), with `max_bytes` set
   from the free JetStream file store measured at creation and at least one
   import record. It is not counted in the profile carve, which stays
   unchanged. Upgraded replicas report not ready until that create has
   succeeded, and core rolls with `maxUnavailable` 0, so no pre-cutover
   replica stops before the stream exists; a failed create pauses the roll
   with the old replicas still consuming. New replicas do not consume
   alert-feeding source streams or route candidates until the cutover marker
   exists, and start owners only for the import (step 2); their other
   consumers run at once. New replicas do not run the `alerts` or
   `alert_recovery` Oban queues. Pre-cutover replicas keep consuming
   sources, admitting to and draining the inbox until they stop.
   Between the last pre-cutover replica stopping and the marker, alert-feeding
   sources lag; nothing is lost. A key's history is therefore one sequence:
   everything admitted to the inbox, then everything routed after the marker.
2. **Cutover task** (coordinator, release N). It waits until no pre-cutover
   core replica remains in the cluster, by capability, and no `alerts` job is
   executing. Then, in order:
   1. Convert every `stateful_alert_rule_states` row into block state
      (compute `virtual_partition`, set `incident_seq` and `renotify_ordinal`
      bases, keep open alert ids) and write an initial checkpoint per block.
   2. Import in bounded segments. The residual set is residual
      `alert_evaluation_work` rows in (rule, position) order (they already
      carry their rule and revision), then residual
      `lifecycle_pending_admissions` rows in (series, seq) order routed
      through the index; each record gets a stable import ordinal. Owners
      start for import only: they consume `alerts.import.v1.b<b>.*` and no
      live subject. For each segment the task measures the free JetStream
      file store and takes the next records up to that size, never above
      the import stream's `max_bytes` and at least one record. It publishes
      them in order on `alerts.import.v1.b<b>.v<vp>`, awaiting each PubAck,
      then a segment-end marker per block. Owners apply the segment and
      checkpoint at the marker; each import message carries its ordinal, and
      a block skips any ordinal at or below the one in its checkpoint. When
      every block's checkpoint covers its segment-end marker, the task purges
      the stream and records the segment's last ordinal in CNPG
      (`alert_cutover_progress`); only then does it publish the next segment.
   3. After the final segment is applied, write the cutover marker. Owners
      then consume live subjects.
   A crash before the marker resumes from the last committed segment: the
   task waits for owners to apply what the stream holds, purges it, and
   republishes from the first ordinal after that segment; owners skip what
   they already applied by ordinal. Nothing is deleted and the source tables
   are untouched until the marker. Once the marker commit has succeeded, a
   rerun of the task is a no-op success: it does not purge, delete or
   republish.
   Imported candidates carry the candidate id the router would compute, so a
   source message the old replicas admitted but did not acknowledge,
   redelivered and routed after the marker, is suppressed as a duplicate.
   Residual work is therefore evaluated before anything routed after the
   cutover, and no live candidate precedes it.
3. **Post-cutover migration** (release N). It refuses to run before the
   marker exists. It drops `alert_evaluation_work`, `alert_evaluation_lanes`,
   `alert_evaluation_receipts`, `stateful_evaluation_ledger` and
   `lifecycle_pending_admissions`, and deletes pending Oban jobs of the
   removed workers.
4. **Release N+1** removes the cutover task, the import subjects, the
   `ALERT_IMPORT_V1` stream and `alert_cutover_progress`.

Removed code: `StatefulAlertEngine.Inbox`, `Owner`, `EvaluationWorker`,
`RecoveryWorker`, `Rollout`, `PeerReadiness`, `Completion` (replaced by
persisted-alert waits), `StatefulEvaluationLedger`, `MetricAlertAdmission`
(folded into the router), `LifecycleAdmissionDrainWorker`, the pending
admission code in `AnalyticsSignals`, the `alert_evaluation_limits` config,
the `alerts` and `alert_recovery` queues, and the Helm env
`SERVICERADAR_ALERT_EVALUATION_MODE`.

### What happens to `alert_evaluation_work` and `lifecycle_pending_admissions`

Both are published to the `ALERT_IMPORT_V1` import stream by the cutover
task in their own order, then dropped in the same release. No row is discarded: each residual
row becomes a candidate that is evaluated before newer input. The receipts
table is dropped too. Its replay role moves to candidate ids (D6) and
deterministic fire keys (D5), and its 7-day volume would be billions of rows
at the target. `stateful_alert_rule_states` is kept, in an extended form, as
the checkpoint store.

The cutover is forward-only (resolved Q9). Before step 2, rolling back is an
ordinary image rollback: no table has been dropped and the inbox still holds
its work.

## Observability

All metrics are published through JetStream and persisted by EventWriter.
Labels are bounded: physical stream, owner node, signal, outcome. Rule ids
and block ids are never metric labels. Per-block detail is served on demand.

- Per stream and per owner: lag in messages, lag age (now minus the publish
  time of the oldest unapplied message), applied/s, duplicates suppressed,
  dropped for a disabled rule, poison skipped, checkpoint age and duration,
  effect commit duration, blocks owned, takeover replay duration, active
  groups and state bytes.
- Router: records routed per signal, no-match ratio, candidates per signal,
  index version and compile time, in-place publish retry seconds, refusals by
  reason.
- Streams: fill percentage, bytes, messages, purge lag; block moves in
  progress and their state. Telemetry streams report the same, and
  collectors report refusals, spool depth and UDP drops.
- Per-block and per-rule cost (candidates/s, lag, groups) are served on
  demand by an RPC to the owners.
- Health: degraded at lag age over 60 s, any block unowned over 30 s
  (`unowned_block_grace_s`, which outlasts a lease expiry), or stream fill
  over 60%. Critical at lag age over 10 min, fill over 85%, poison skipped,
  permanent effect failures, or a block move stalled over 10 min. Every
  threshold is a CNPG setting (D11). Capacity recommendations (D12) are
  reported as health advisories with the setting value to apply. One health
  event per transition, from the coordinator.

## Benchmark gates

Each gate has an explicit failure branch and reads artifacts, not job status.
Synthetic generators invent everything: device uids `sr:synthetic-dev-NNNNNN`,
hostnames `hostNNNNNN.example.com`, addresses from `2001:db8::/32` (the only
documentation range large enough for 100,000 distinct devices), and invented
rule and site names. Generated candidates carry a per-key sequence number so
an order violation is detectable.

| Gate | Where | What | Fails when |
|---|---|---|---|
| G1 router | RBE, per PR (BazelCI) | 500 stateful + 200 promotion synthetic rules; 1M synthetic logs, events and points | under 200k records/s per core, or p99 per-record cost over 20 us for logs/events or 5 us for metric points |
| G2 owner | RBE, per PR, real `nats-server` + srql-fixtures CNPG | one owner at 10,000 candidates/s for 10 min, 200k active groups | lag age p99 over 2 s, checkpoint commit p99 over 500 ms, or memory over 1.5 KB per group plus the dedupe ring |
| G3 exactly-once | RBE, per PR | fault injection: kill before effect commit, after effect commit and before checkpoint, mid checkpoint, mid replay; kill a router between two publishes of one key; steal a lease; duplicate publishes inside and outside H; poison candidate with a full DLQ; permanent effect failure; property-based replay from random checkpoints | any fire key missing or applied twice against the single-run oracle, any occurrence counted twice within H, or a stale epoch commit accepted |
| G4 fleet scale | in-cluster disposable namespace (resolved Q7), nightly and required before every release cut | 50k then 100k synthetic devices at the `capacity.md` sustained rates for 30 min, a 5 min burst at A10, then one core replica killed mid-burst | any discarded or terminally delivered message, any DLQ entry, any fired-alert set that differs from the generator's oracle, any per-key order violation, sustained lag age p99 over 30 s, alert fire latency p99 over 15 s, burst not drained to lag age under 5 s within 10 min, takeover over 30 s, core CPU over 70% or RSS over 75% of limit at sustained, alert-path CNPG writes over 5,000 rows/s, or more than 2 Stream Loads/s per table per replica |
| G5 semantics | RBE, per PR | golden effect traces for every row of the semantics table, captured from the current engine on synthetic scenarios before it is deleted, replayed through the new evaluator | any trace difference |
| G6 resharding under load | in-cluster, with G4 | at the 100k sustained rate: split the candidate stream 1 -> 2 -> 4, merge 4 -> 2, split each telemetry stream 1 -> 4, add and remove a core node, and kill the coordinator mid-move | any loss, duplicate alert or per-key order violation against the oracle, any terminal or discarded message, a move that does not complete after a coordinator kill, or lag age over 60 s for more than 2 min per move |
| G7 small install | RBE, per PR | one core node, one candidate stream, one stream per signal, 5 candidates/s for 30 min, then 30 min idle | idle owner CPU over 1% of a core, owner memory over 50 MB, alert-path CNPG statements over 1/s while idle (lease renewals only), or a fire latency p99 over 2 s |

G4 passes at 50k with at least 30% headroom before it runs at 100k. Its
report records the measured numbers that replace the estimates in
`capacity.md` 1.4 and the per-stream bounds the D12 recommendations use.

## Risks / Trade-offs

- **Determinism is a discipline.** One wall-clock read or database read in a
  decision silently breaks the replay proof. Mitigation: the evaluator is a
  pure module with effects as data, G3 replays from random checkpoints, and a
  test asserts that the evaluator modules call no Repo, Ash or `DateTime.utc_now`.
- **Block moves depend on NATS subject binding semantics** (refusing
  overlapping subjects, and refusing publishes to unbound subjects). G6 runs
  against the pinned `nats-server` version and must be rerun on every NATS
  upgrade.
- **A larger NATS footprint at scale.** R3 candidate and telemetry streams
  sized for outages need the `xlarge` profile at the design point. The
  render-time budget check covers the new streams. A small install keeps one
  stream per signal and one candidate stream.
- **A stuck block eventually stalls ingestion.** That is the explicit price
  of never losing evaluations. It is critical in health long before.
- **Alert visibility can precede warehouse queryability** by up to the
  coalescing age.
- **Forward-only cutover.**
- **Per-block source durables.** Each alert-feeding telemetry stream carries
  one durable per block, 128 per stream. G7 measures their idle cost on a
  small install.
- **Scope.** This touches EventWriter, collectors, NATS profiles, web-ng and
  core. Tasks are ordered so that the alert path ships first on one candidate
  stream, together with the block-subject source streams and their leased
  routers, because per-key order depends on them; that is enough for every
  current install. Resharding, telemetry stream counts above one and the
  collector work follow behind the same gates.

## Resolved Questions

Answered by the user on 2026-11-04.

**Q1. Target rates and retention.** Adopt `capacity.md` A1-A16 as the
target. StarRocks keeps the one-year default retention. The storage
implication at 100,000 devices, about 0.5-1 PB of object storage, is stated
in `capacity.md` 1.4 and goes into the operator documentation (task 7.3,
the capacity planning page).

**Q2 and Q3. Partitioning and checkpoints.** Elastic, not a fixed 64: 1,024
fixed virtual partitions under a versioned hash, 128 blocks, a dynamic block
map onto physical streams and owners, and online split and merge (D2, D3,
D12). A small install runs one candidate stream and one owner per core node.
Stream count, owner placement, checkpoint interval and candidate cap are CNPG
runtime settings with small-install defaults (D11). Resharding is
operator-triggered from health recommendations, with an opt-in automatic
mode (D12). The same elasticity applies to the telemetry streams (D10). Gates
G6 and G7 were added.

**Q4. Candidate stream outage budget.** 1 h of stored (S2-compressed) bytes
at the sustained candidate rate, as the profile-derived code default of the
CNPG stream size setting, using a conservative 2:1 S2 ratio that G4 measures
and confirms. The 180 GB design-point figure is the volume before
compression.

**Q5. Duplicate suppression.** The persisted 128-bit candidate-id ring with a
10 min horizon (D6), with the NATS duplicate window at its minimum.

**Q6. Raw log rules.** `signal: :log` rules are evaluated through the index
(D1). The `observability-signals` delta for "Stateful rules evaluate OCSF
events" is included in this change.

**Q7. Where the fleet gate runs.** An in-cluster disposable namespace,
nightly and as a required pre-release check. G1-G3, G5 and G7 stay on RBE
per PR.

**Q8. Overflow at the edge.** Accepted: DiscardNew streams move overflow to
the publishers. Collectors spool and count. UDP and trap sources, which
cannot be retransmitted, are refused and counted at the collector.

**Q9. Cutover.** Forward-only. There is no reverse importer.

## Open Questions

None at this time. New questions found during implementation go here,
with options and a recommendation, before the work they affect.
