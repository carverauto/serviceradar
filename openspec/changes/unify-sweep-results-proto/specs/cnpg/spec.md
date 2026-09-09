# cnpg Delta

## ADDED Requirements

### Requirement: Edge durable record projection is idempotent
CNPG SHALL store an ingest ledger and contract-specific domain uniqueness
constraints sufficient to make sweep, execution, OCSF, MTR trace/hop,
inventory, metric/event, and approved extension projection idempotent
under retries beyond the JetStream duplicate window. The ledger SHALL be keyed
ONLY by (`network_scope_id`, semantic event ID) -- a metadata retention bucket
deterministically derived from the semantic event ID MAY join the physical SQL
partitioning key. It SHALL STORE authenticated agent, exact output-contract
bundle, authenticated producer/package/assignment/run context, immutable
`traffic_class`, immutable `semantic_envelope_sha256` (the sole conflict/replay
comparison value), encoded and projected-write byte counts, cost-model version,
expected/projected record counts, and commit state as immutable COMPARISON
VALUES that a conflicting record is checked against -- never as lookup-key
components -- and without storing a duplicate payload body. `record_sha256` is
NOT a ledger conflict-comparison value; it lives on the DELIVERY-SLOT binding as
the physical-slot conflict comparison. The SQL delivery-slot uniqueness binding,
keyed by the frozen `edge_slot` tuple, SHALL be created for EVERY gateway-accepted
delivery -- primary, audit, replay, poison, and conflict -- BEFORE its source ACK,
recording `record_sha256` as the compared value; for poison and conflict deliveries
the binding is audit-only and drives NO domain projection. A DLQ-ACKed poison or
conflict record therefore still leaves an immutable slot binding, so a later frame
reusing the same `edge_slot` with a different `record_sha256` is detected as a
transport-integrity conflict rather than silently accepted. An IDENTICAL SQL
service-slot uniqueness binding, keyed by the frozen `service_slot` tuple
(`network_scope_id`, `authenticated_service_id`, `publication_lane_id`,
`publication_sequence`), SHALL be created for EVERY accepted governed-service
delivery -- alongside `edge_slot` and following the same rules -- BEFORE its source
ACK, recording `record_sha256` as the compared value, so a service-ingress frame
reusing one `service_slot` with a different `record_sha256` is likewise detected as
a transport-integrity conflict rather than silently accepted. On an
`EVENT_ID_CONFLICT`, the conflict
DLQ path SHALL retain the first-accepted `record_sha256` as MANDATORY audit-only
forensic provenance -- not optional -- and that retained `record_sha256` is
EXCLUDED from replay/conflict comparison; only `semantic_envelope_sha256`
decides ledger replay versus conflict. Every
address-derived domain key and deterministic derived-event key SHALL begin with
the authoritative `network_scope_id`. Every v1 semantic event ID SHALL be
RFC 9562 UUIDv7; the metadata bucket / partition selection and the
collection/execution-timing agreement SHALL be validated against the
authoritative body observation/event time (with the UUIDv7 timestamp checked
for consistency, not trusted in isolation) so one ID cannot move between ledger
partitions.

#### Scenario: Committed event is replayed
- **WHEN** the same event is received again for the same (`network_scope_id`,
  semantic event ID) ledger key (in its event-ID-derived metadata bucket) with a
  matching stored `semantic_envelope_sha256` (and matching stored agent and
  contract comparison values)
- **THEN** the projector SHALL detect its committed ledger entry without
  repeating domain side effects
- **AND** return success so the JetStream delivery can be acknowledged

#### Scenario: Event ID has conflicting content
- **WHEN** the same namespaced semantic event ID is received with a different
  immutable `semantic_envelope_sha256`
- **THEN** the transaction SHALL reject it as a protocol integrity error
- **AND** SHALL NOT overwrite or merge the committed domain rows

#### Scenario: Projector crashes before commit
- **WHEN** a database transaction fails or the process exits before commit
- **THEN** neither the ledger commit nor partial domain side effects SHALL be
  visible
- **AND** a redelivery SHALL safely retry the complete bounded transaction

#### Scenario: Two events claim one sweep batch sequence
- **GIVEN** one network-scope/execution/shard/assignment-epoch/batch-sequence
  slot is already bound to an event ID, `semantic_envelope_sha256`, traffic
  class, counts, and projected rows
- **WHEN** another event claims that slot with any different binding
- **THEN** the projector SHALL retain the first authenticated committed binding,
  classify the later claim as poison, and SHALL NOT overwrite or merge it
- **AND** the attempt SHALL become `integrity_failed` and its range SHALL be
  retried under a new fenced epoch before authoritative reconciliation completes

#### Scenario: One delivery slot is reused for different semantics
- **GIVEN** a delivery slot whose SQL uniqueness is keyed by the frozen
  `edge_slot` tuple (`network_scope_id`, `authenticated_agent_id`, `spool_id`,
  `sequence`) -- with the partition bucket derived from that tuple,
  NOT part of the uniqueness key -- is bound to one event ID and semantic digest
- **WHEN** a frame claims that slot with a different event ID or semantic digest
- **THEN** the projector SHALL classify the later claim as poison before domain
  side effects
- **AND** the original delivery-slot binding SHALL remain immutable

#### Scenario: One service slot is reused for different bytes
- **GIVEN** a governed-service delivery whose SQL uniqueness is keyed by the frozen
  `service_slot` tuple (`network_scope_id`, `authenticated_service_id`,
  `publication_lane_id`, `publication_sequence`) is bound to one `record_sha256`
  BEFORE its source ACK
- **WHEN** a later service-ingress frame claims that `service_slot` with a different
  `record_sha256`
- **THEN** the projector SHALL detect the transport-integrity conflict rather than
  silently accept it
- **AND** the original `service_slot` binding SHALL remain immutable

#### Scenario: Poison or conflict delivery still binds its slot
- **GIVEN** a gateway-accepted delivery is classified as poison or as an
  `EVENT_ID_CONFLICT` and is destined for a DLQ ACK
- **WHEN** the projector resolves its disposition
- **THEN** an immutable `edge_slot`-keyed binding recording `record_sha256` SHALL
  be created BEFORE the source ACK as an audit-only binding that drives no domain
  projection
- **AND** a later frame reusing the same `edge_slot` with a different
  `record_sha256` SHALL be detected as a transport-integrity conflict rather than
  silently accepted

#### Scenario: Recovery republishes unchanged semantic data
- **GIVEN** spool recovery assigns an unchanged event a new fenced delivery-only spool ID or sequence
- **WHEN** the recovered delivery reaches the projector with its original
  semantic event ID, digest, traffic class, collection proof, and scope
- **THEN** a new delivery-slot binding MAY be created for the new coordinates
- **AND** the semantic ledger SHALL deduplicate the event while authoritative
  attempt fencing still governs every state-changing effect

#### Scenario: Two terminal events claim one agent terminal slot
- **GIVEN** an agent terminal slot keyed by network scope, execution, shard,
  and assignment epoch already binds one terminal kind, event, closed batch
  interval, counts, outcomes, and the versioned MTR COMPLETION digest (there is no
  MTR range root: `range_root_sha256` is RETIRED, tag 20 reserved)
- **WHEN** a conflicting terminal binding or a data batch outside that closed
  interval is projected in any arrival order
- **THEN** the first authenticated terminal binding SHALL remain immutable
- **AND** the attempt SHALL become `integrity_failed`, be excluded from
  authoritative reconciliation, and have its range repaired under a new fenced
  epoch
- **AND** scheduler-authored lost, expired, or superseded state SHALL occupy a
  separate authoritative assignment-state slot rather than agent evidence

### Requirement: Observation writes are bounded and horizontally consumable
The database writer SHALL treat every result event as independently decodable,
costed, and idempotent. It MAY apply one or more already validated events in one
bounded adaptive transaction to amortize commit/WAL overhead, but SHALL bound the
group's aggregate encoded/resident bytes, projected write bytes, rows, message
count, lock set, and duration. It SHALL NOT cross traffic classes or incompatible
schema/projector semantics, reassemble an execution, or hold a global execution
lock before writing observations. Stable keys and observation-time guards SHALL
permit concurrent partition workers. Sweep rows SHALL preserve the
scheduler-issued assignment epoch so reconciliation can fence stale owners.
Every constituent event SHALL retain its own ledger/slot outcome and SHALL be
explicitly ACKed only after the containing transaction commits.
Logical partitions SHALL provide concurrent decode/project work but SHALL NOT be
treated as independent CNPG write capacity. The row budget SHALL conservatively
include delivery slots, ledger, identity, current/history, execution, OCSF,
correlation, outbox, and reconcile-work mutations, including fixed per-message
overhead. Before SQL, projectors SHALL canonical-sort every overlapping conflict
key and acquire tables and rows in one documented global order. Raw sweep history
SHALL use an immutable Timescale partition `identity_time` derived only from the
scheduler-owned execution epoch. A unique history-row key containing that time,
network scope, agent, execution, shard, assignment epoch, address, mode, and mode
revision SHALL bind canonical observation time and semantic digest. The projector
SHALL reject agent-supplied alternate partition placement and SHALL NOT create a
permanent non-hypertable identity side row for every observation.

#### Scenario: Execution batches arrive on multiple partitions
- **WHEN** independently keyed execution shards are consumed concurrently
- **THEN** each SHALL commit without a global scan transaction
- **AND** hot execution totals SHALL be reconciled from unique committed ranges
  plus immutable execution plans and authoritative attempt state/evidence rather
  than incremented for every delivery

#### Scenario: Sparse frames are grouped for commit
- **GIVEN** many agents flush small valid frames on their byte/count timers
- **WHEN** a persistence worker forms a transaction group
- **THEN** it MAY group messages across agents/executions within one traffic
  class and compatible projector while respecting every aggregate cost/deadline
  bound
- **AND** a group failure SHALL ACK no constituent and SHALL be split or retried
  idempotently to isolate a deterministic conflict

#### Scenario: Database-wide write pressure reaches its limit
- **GIVEN** multiple network scopes, agents, traffic classes, partitions,
  consumers, or EventWriter replicas target one CNPG primary
- **WHEN** shared row/byte/transaction credits or Repo/WAL/lock thresholds are
  exhausted
- **THEN** all relevant pulls SHALL pause or remain within their already-bounded
  in-flight work and fixed reserved recovery/control subpools
- **AND** per-consumer ack-pending settings SHALL NOT multiply database
  concurrency beyond the shared limit

#### Scenario: Pull reserves worst-case capacity
- **WHEN** a source projector requests a bounded pull
- **THEN** it SHALL first reserve maximum encoded/resident bytes, projected
  write bytes, and rows for each requested message plus one transaction-
  concurrency slot for every aggregate transaction it may execute concurrently
  from a fenced expiring destination grant
- **AND** after authenticated decode it MAY refund to verified actual cost but
  SHALL retain those credits through queued processing and disposition
- **AND** a sequential split SHALL reuse a slot only after confirmed rollback,
  while a parallel split SHALL acquire another slot and every commit SHALL consume
  the separately bounded destination commit-rate/fsync budget

#### Scenario: All runtime writers compete during catch-up
- **GIVEN** source ingestion, AGE outbox, parent reconciliation, spool recovery,
  DLQ indexing/redrive, rollup, and repair work target one primary
- **WHEN** they run concurrently after an outage
- **THEN** their grants and reserved subpools SHALL sum to one hard destination
  limit while preserving recovery/control progress
- **AND** database statement/transaction timeout SHALL NOT exceed the grant
  deadline, and expired capacity SHALL be reissued only after backend cancellation
  or session death is confirmed (otherwise old capacity remains charged)
- **AND** crash, lease expiry, or rolling scale overlap SHALL NOT allocate the
  same capacity twice

#### Scenario: Parent execution receives many batch commits
- **WHEN** many partitions commit per-shard execution evidence concurrently
- **THEN** their transactions SHALL NOT contend on one parent execution-summary
  or substitute `(network_scope_id, execution)` dirty-row update
- **AND** each SHALL insert append-only source-keyed reconcile work into a fixed
  hash-partitioned queue carrying immutable source traffic class
- **AND** a fenced/leased reconciler SHALL coalesce bounded work per execution,
  derive parent totals from unique committed ranges and authoritative terminal
  evidence, and atomically mark only its claimed work processed

#### Scenario: Bulk and interactive reconciliation compete
- **GIVEN** bulk catch-up has filled its reconciliation claim queue while
  interactive execution evidence continues to arrive
- **WHEN** reconcilers claim bounded work
- **THEN** disjoint class-aware claim queues and weighted-fair selection SHALL
  preserve reserved interactive credits and a bounded interactive drain delay
- **AND** replay or derived work SHALL retain its immutable source traffic class
  and SHALL NOT promote bulk work into the interactive reserve

#### Scenario: Reconcile notification or worker is lost
- **WHEN** a process crashes after evidence commit or during parent reconciliation
- **THEN** append-only work state or bounded anti-entropy SHALL make the
  execution eligible again
- **AND** no in-memory PubSub/job enqueue SHALL be required for eventual
  correctness

#### Scenario: Older state arrives late
- **WHEN** an older host observation commits after a newer current-state update
- **THEN** retained history MAY record the observation
- **AND** current device availability, last-seen, and port state SHALL not move
  backward in observation time

#### Scenario: Mode fragments arrive out of order
- **GIVEN** a later MTR fragment arrives before an earlier ICMP/TCP fragment for
  the same host
- **WHEN** both are projected
- **THEN** revisions SHALL be compared independently per reported mode
- **AND** availability SHALL be derived from merged per-mode outcomes and the
  versioned policy rather than one fragment-global boolean

#### Scenario: Reassigned shard receives stale data
- **WHEN** a result from an older assignment epoch commits after its shard range
  has been fenced to a replacement
- **THEN** raw audit history MAY retain the attempt
- **AND** reconciled execution counts and current device state SHALL select only
  the scheduler-authoritative epoch and revision

#### Scenario: Observation arrival permutations produce derived events
- **GIVEN** authoritative older and newer state observations arrive in either
  order
- **WHEN** their bounded event-time epoch closes
- **THEN** each observation SHALL have one deterministic immutable OCSF event
- **AND** the watermark reconciler SHALL produce the same lifecycle transition
  IDs/state in either permutation, using explicit correction/retraction events
  for data admitted after a finalized watermark

#### Scenario: Sweep identity attempts to move across Timescale chunks
- **GIVEN** two events carry the same network scope, agent, execution, shard,
  assignment epoch, canonical address, mode, and mode revision
- **WHEN** their claimed observation times or contents differ
- **THEN** both SHALL derive the same scheduler-owned `identity_time` and contend
  on the same unique history-row key
- **AND** the first authenticated binding SHALL immutably bind canonical
  observation time and semantic digest in that partition
- **AND** repackaging the same semantic observation in another event or batch
  SHALL NOT move it to another partition or bypass the conflict guard

#### Scenario: Concurrent batches overlap domain keys
- **GIVEN** two otherwise valid batches contain overlapping identity,
  current-state, or summary keys in different input orders
- **WHEN** their transactions execute concurrently
- **THEN** projectors SHALL canonical-sort bulk conflict keys and acquire tables
  and rows in one documented global order
- **AND** every `INSERT ... ON CONFLICT` input SHALL follow that same order so
  bounded concurrency does not become a deadlock/retry storm

### Requirement: Database installation capacity is hard-partitioned and fenced
The installation-level CNPG admission plan SHALL partition both connections and
measured Repo, WAL, lock, resident-byte, write-byte, row, active-transaction, and commit-rate/fsync
capacity into explicit result-data-plane, sync, control/API/Oban, and
background/maintenance pools. Pool maxima plus database-internal and otherwise
ungoverned work charged as unavailable reserve SHALL NOT exceed the hard
destination limit. Result admission SHALL cover source projection, graph
outbox, execution reconciliation, recovery, DLQ indexing/redrive, rollup, and
repair through one fenced controller with separately reserved recovery,
reconciliation, and interactive progress floors.

#### Scenario: Every runtime workload is active
- **GIVEN** results, sync, API/control, Oban, maintenance, and database-internal
  work all target one CNPG primary
- **WHEN** installation readiness or admission is evaluated
- **THEN** their maximum connections and capacity reservations SHALL sum to no
  more than the measured hard destination limits
- **AND** scaling one pool SHALL NOT consume another pool's floor or assume
  ungoverned work is absent

#### Scenario: A result pull is admitted in two stages
- **WHEN** a result worker requests messages
- **THEN** it SHALL first reserve worst-case encoded and resident bytes,
  projected write bytes, rows, and transactions for every requested message
- **AND** after authenticated decode it MAY return only the verified unused
  delta while retaining actual credits through bounded queueing, commit or
  failure, and delivery disposition

#### Scenario: A fenced grant expires during database work
- **GIVEN** a distributed grant has a monotonically fenced generation, expiry,
  and maximum transaction deadline
- **WHEN** its worker reaches the pre-commit boundary after the generation was
  fenced or the lease expired
- **THEN** the transaction SHALL recheck the grant and roll back rather than
  commit
- **AND** expired capacity SHALL be reissued only after database-session
  cancellation or death is confirmed; otherwise its worst-case capacity SHALL
  remain charged

#### Scenario: Admission controller is unavailable during scale overlap
- **WHEN** a worker cannot obtain a grant whose lease outlives its transaction
  deadline, or old and new generations overlap during a rollout
- **THEN** it SHALL NOT start a new pull or transaction
- **AND** unconverted writers SHALL retain a static worst-case reservation until
  they are fenced and drained

### Requirement: Sweep and MTR storage is tiered by query purpose
CNPG SHALL separate current device state, execution summaries, bounded raw sweep
history, raw MTR traces/hops, and longer-lived aggregate views. Raw retention,
chunk intervals, compression, indexes, and rollup policies SHALL be derived from
measured ingest/query/WAL/storage behavior and SHALL avoid row-by-row expiry
storms. Existing operator-configured MTR retention SHALL remain authoritative
within benchmarked safe bounds. Migrations and control-plane reconciliation,
not EventWriter, SHALL own retention and compression policy DDL.

Correctness metadata SHALL have a finite accepted replay horizon and trusted
retirement buckets covering maximum agent spool/offline, JetStream redelivery/
retention, compatible rollback, repair, and integrity-audit horizons. Ordinary
delivery/terminal/batch slots, ingest ledger, and resolved expectation/
correlation state SHALL retire by whole partition after durable source watermarks
pass the bucket. Each ordinary delivery/terminal/batch slot partition bucket
SHALL derive from that slot's immutable slot coordinates, NOT from the event ID,
while the ingest-ledger partition bucket SHALL derive from the semantic event ID,
so reusing one slot with a different event ID cannot select another partition and
evade the binding. Each non-ledger slot partition key SHALL be the FROZEN ordered pair
`(ordered_time_bucket, hash_subshard)`. `ordered_time_bucket` is the slot type's
epoch coordinate floored to a fixed retention window (one window per configured
retention granularity) and SHALL be CHRONOLOGICALLY ORDERED so a whole expired
window is dropped by a single range `DROP`/detach, never a hash scan.
`hash_subshard` is the low N bits of `SHA-256(slot-tuple)` at a fixed width
(for example 8 bits -> 256 subshards), and SHALL spread write load only WITHIN a
window. The epoch coordinate (carried on the slot binding or deterministically
derivable) and the tuple hashed for the subshard SHALL be frozen per slot type:
the delivery slot uses epoch = spool generation epoch and subshard =
`hash(edge_slot)`; the sweep-batch slot uses epoch = assignment epoch and
subshard = `hash(network_scope_id, execution, shard)`; the agent-terminal slot
uses epoch = assignment epoch and subshard = `hash(network_scope_id, execution,
shard)`; the service-ingress slot uses epoch = publication epoch and subshard =
`hash(service_slot)`. A single `SHA-256(epoch-coordinate || slot-tuple)` truncated
to a fixed bucket SHALL NOT be used, because it mixes every epoch into the same
bucket forever and cannot be dropped chronologically. The ingest-ledger partition
bucket keeps its semantic `event_id` UUIDv7 time window, which is already
chronological; it SHALL NOT change. Long-retained current state, summaries, rollups, or query history
SHALL NOT pin ordinary correctness partitions after their immutable projection
can no longer produce side effects.

Before an unresolved DLQ, recovery, rollback, graph-repair, or other exceptional
item crosses the ordinary watermark, CNPG SHALL atomically create a bounded
`correctness_hold` with semantic identity, first `semantic_envelope_sha256`/`payload_sha256`, original class,
source catalog locator, state, domain-replay deadline, and the complete bounded
input needed to finish the work inline or through a checksummed content-addressed
payload owned by the hold. Before ordinary partition retirement, inline
graph/outbox/task input SHALL be atomically copied into held storage or its
existing content-addressed payload SHALL be pinned; a digest-only hold SHALL NOT
permit retirement. Redrive below the
ordinary watermark SHALL require that hold. After its domain-replay deadline,
resolution SHALL be audit/partial/recollection-only. Non-held older delivery
SHALL terminate as `replay_horizon_expired` after one bounded stable audit record
and SHALL NOT recreate domain or correctness rows.

The installation SHALL enforce hard correctness-metadata row/index-byte and held-
payload byte budgets. If watermark progress, whole-partition retirement, or finite exceptional
capacity cannot keep ordinary metadata within the admitted replay window and
holds within their configured capacity, new scan admission SHALL stop before the
budget is exceeded.

#### Scenario: Raw history expires
- **WHEN** a sweep or MTR raw-history chunk exceeds configured retention
- **THEN** it SHALL be retired through partition/hypertable policy without
  deleting current state or execution summaries
- **AND** retained rollups SHALL remain queryable for their configured window

#### Scenario: Capacity gate is evaluated
- **WHEN** the 1M-host benchmark and MTR budget are measured
- **THEN** operators SHALL record sustained insert/hop rates, index and WAL
  amplification, compression ratio, retention bytes, and representative query
  latency
- **AND** fleet rollout SHALL not proceed unless projected storage and backlog
  drain remain within the approved safety margin

#### Scenario: Correctness metadata reaches its safe watermark
- **WHEN** every replay source and dependent reference for a completed event is
  provably beyond its retention/audit horizon
- **THEN** its ordinary correctness bucket SHALL retire through whole-partition
  detach/drop rather than row-by-row deletion
- **AND** unresolved exceptional state SHALL already have a bounded
  `correctness_hold` rather than pin the ordinary partition

#### Scenario: Old delivery has no correctness hold
- **GIVEN** a delivery is below the durable ordinary acceptance watermark
- **WHEN** no exact unresolved `correctness_hold` authorizes domain replay
- **THEN** it SHALL receive a stable `replay_horizon_expired` audit disposition
- **AND** SHALL NOT recreate expired raw history, mutate current state, or insert
  new ordinary correctness metadata
