# ingestion-routing Delta

## RENAMED Requirements

- FROM: `### Requirement: Broker-Free Large Payload Handling`
- TO: `### Requirement: Large payload routing follows durability semantics`

## MODIFIED Requirements

### Requirement: Large payload routing follows durability semantics
Persistent records SHALL NOT use broker-free large-payload ingestion. The system
MAY finish and drain already-accepted pre-cutover sync payloads through bounded
streaming gRPC chunking. Durable
inventory, telemetry, findings, events, traces, observations, and other
persistent records produced by an agent-side integration SHALL use bounded typed
records through the durable producer plane and JetStream/EventWriter. The legacy
broker-free sync route SHALL NOT become a persistence path for a new or migrated
durable output contract. Non-persistent command/configuration and coalescible
status MAY remain broker-free.

#### Scenario: Pre-cutover sync payload delivered via chunks
- **GIVEN** a legacy sync source accepted bounded work before its hard cutover
- **WHEN** that pre-cutover payload exceeds a single compatibility message
- **THEN** it MAY be delivered as multiple gRPC chunks to the legacy sync
  ingestor
- **AND** no newly defined persistent dataset SHALL use that exception

#### Scenario: Agent integration emits durable inventory
- **WHEN** an Armis or other agent-side integration produces persistent
  inventory pages
- **THEN** each page SHALL enter the common durable producer sink and JetStream
  record plane before EventWriter projection
- **AND** broker-free gRPC/ERTS SHALL NOT acknowledge it as durably ingested

## ADDED Requirements

### Requirement: Edge durable records use layered transport and durability
Agent-originated durable records SHALL use layered transport and durability.
Persistent observations, telemetry, inventory, findings, execution events,
traces, and approved extension records SHALL use
mTLS gRPC for the edge hop and installation-local JetStream for durable commit,
replay, fan-out, and downstream backpressure. The gateway SHALL be the sole
JetStream ingress publisher for these agent-originated durable record types.
`network_scope_id` SHALL identify the authoritative site/address-space namespace
inside the single-customer installation. It SHALL NOT be treated as a SaaS
customer or require a dedicated broker account, physical stream, database
schema, or capacity cell. It MAY remain an installation-local fairness,
admission, and identity dimension so one site or address space cannot monopolize
shared resources.

#### Scenario: Edge record reaches durable ingress
- **GIVEN** an authenticated agent has a completed durable record frame
- **WHEN** it sends the frame over the edge record stream
- **THEN** the gateway SHALL publish the exact agent-spooled `EdgeRecordV1`
  bytes from the delivery frame, byte-for-byte, to its
  fixed installation-local subject selected by its platform route profile,
  immutable traffic class, and logical partition
- **AND** the database SHALL be written only by the corresponding event-writer
  consumer after durable publication

#### Scenario: Agent-side integration emits inventory pages
- **GIVEN** an embedded Armis or other provider integration emits persistent
  inventory pages
- **WHEN** each bounded page becomes available
- **THEN** it SHALL be fsynced and durably published through this record plane
  without waiting for the provider run to complete
- **AND** it SHALL NOT use broker-free `StreamStatus` as an alternate persistent
  ingestion path

#### Scenario: Inventory terminal activates a complete snapshot
- **GIVEN** an inventory run has durably published independently useful pages
- **WHEN** its terminal manifest and every declared page/hash commit through the
  approved inventory projector
- **THEN** the projector SHALL atomically activate the completed source generation
- **AND** a missing, partial, aborted, or unproven terminal SHALL preserve the
  prior current snapshot and SHALL NOT infer absence/deletion

#### Scenario: Non-persistent control data remains direct
- **WHEN** an agent sends bounded command, configuration, credential, heartbeat,
  or coalescible current-status data
- **THEN** it MAY continue to use direct gRPC/ERTS control routing
- **AND** that path SHALL NOT acknowledge a new durable dataset contract

### Requirement: A large execution is a stream of independent micro-batches
A sweep or MTR job SHALL be represented as a logical execution stream containing
start, zero or more independently decodable data micro-batches, bounded
progress/watermark events, and terminal evidence when the agent can emit it. A
scheduler-authored immutable execution plan SHALL define expected shards/ranges,
while separate append-only assignment attempts define owners/epochs. Every
attempt SHALL eventually have one authoritative terminal state, including a
scheduler-authored lost/expired/superseded state when agent terminal evidence is
absent. No hop SHALL require reconstruction of the full execution payload before
processing durable data.

#### Scenario: Results flow before the scan completes
- **GIVEN** a large sweep is still scanning later target windows
- **WHEN** an earlier host window reaches terminal outcomes
- **THEN** the agent SHALL batch, spool, transmit, and durably ingest those host
  observations without waiting for the complete sweep
- **AND** downstream consumers SHALL commit those micro-batches independently

#### Scenario: Completion reconciles streamed data
- **GIVEN** an execution has emitted multiple data batches
- **WHEN** authoritative assignment terminal state or agent evidence is committed
- **THEN** the execution tracker SHALL reconcile unique committed sequences,
  counts, and terminal shard ranges against the immutable execution plan and
  authoritative attempt records/evidence
- **AND** missing ranges SHALL leave the execution visibly partial rather than
  falsely complete

#### Scenario: Terminal sequence contains a gap
- **GIVEN** one assignment attempt allocates one contiguous sweep-batch sequence
  beginning at one and terminal evidence closes sequence `3`
- **WHEN** only batch slots `1` and `3` have committed
- **THEN** the attempt SHALL remain incomplete because slot `2` is missing
- **AND** concurrent builders SHALL NOT create intentional gaps or independent
  sequence spaces inside that attempt

#### Scenario: Terminal evidence conflicts with an attempt slot
- **GIVEN** one network-scope/execution/shard/assignment-epoch agent-terminal slot
  already binds an authenticated terminal event, closed batch interval, counts,
  outcomes, and versioned MTR range roots
- **WHEN** different terminal evidence or a batch outside that closed interval
  arrives in any order
- **THEN** the first authenticated terminal-slot binding SHALL remain immutable
- **AND** the attempt SHALL become `integrity_failed`, remain incomplete, and
  have its range repaired under a new fenced epoch

#### Scenario: No broker arrival-order dependency
- **GIVEN** well-formed non-conflicting events from different executions,
  shards, attempts, or one shard's asynchronous publishes arrive out of sequence
- **WHEN** consumers receive data and agent start/progress/terminal evidence in
  any order
- **THEN** consumers SHALL process them independently using stable execution,
  shard, assignment, sequence, revision, and event identifiers
- **AND** correctness SHALL NOT depend on broker arrival order within or across
  partitions
- **AND** every delivery permutation SHALL converge on the same current state and
  deterministic observation/transition event ID set after its event-time
  watermark closes

#### Scenario: Transport stream lifetime is not execution lifetime
- **GIVEN** one long-lived record RPC carries frames for multiple executions
- **WHEN** an assignment attempt finishes or the connection reconnects
- **THEN** completion SHALL be determined from authoritative assignment state,
  any stable terminal evidence, and plan/range reconciliation, not RPC close or
  EOF
- **AND** other executions SHALL continue or resume on the same logical lanes
  without waiting for a whole connection drain

### Requirement: Edge records and delivery frames are byte-bounded and versioned
Every `EdgeRecordV1` SHALL declare its platform payload family, exact output-
contract ID/version/bundle digest and registry epoch, authenticated producer/
package/assignment/run context, platform route profile, schema version,
compression, encoded and uncompressed sizes, checksum, stable event ID,
projected database-row cost, projected database-write bytes, and cost-model
version. It SHALL also declare exactly one authoritative `network_scope_id`,
immutable signed `traffic_class`, authorization kind/context, and any source/run/
execution/shard/epoch/range ID/digest covered by its signed capability. Trusted
projected cost, route, traffic class, and provenance SHALL be derived by the
agent sink from the approved contract/grant rather than accepted from a producer.
The agent sink SHALL encode these complete producer-neutral semantic record bytes
once. Their semantic digest SHALL bind network scope, authenticated agent,
traffic class, output/schema/cost contract, authorization, producer/run,
execution, assignment, range, observation identity, and canonical content.

Every `EdgeDeliveryFrameV1` SHALL carry the exact `EdgeRecordV1` bytes and digest
plus persistent spool identity, monotonic lane sequence, and other bounded edge-
delivery/session coordinates. Delivery coordinates SHALL NOT be part of the
canonical semantic record or its digest. Recovery MAY wrap the same record bytes
in a new fenced delivery frame without changing semantic identity. Gateway
receipt, physical stream/sequence, and stream-map placement are broker placement
metadata and SHALL NOT be injected into or rewrite `EdgeRecordV1`.

The gateway SHALL validate the delivery frame and enough of the fixed semantic
record to authorize and route it, then JetStream-publish the exact `record_bytes`
unchanged. Broker
headers SHALL be transport-minimal, limited to protocol fields required for
deduplication, expected-stream fencing, and bounded tracing; they SHALL NOT
duplicate semantic metadata or act as identity, contract, authorization, cost,
or routing authority. EventWriter SHALL decode and validate the complete binary
`EdgeRecordV1` from the JetStream body. Broker publication identity SHALL bind trusted
network scope/agent, lane, spool ID/sequence, and the semantic digest. The
initial `EdgeRecordV1` target encoded size SHALL be 256 KiB and its hard encoded
size SHALL be 512 KiB. `EdgeDeliveryFrameV1` and transport-minimal broker headers
SHALL add only separately bounded overhead.

#### Scenario: Exact binary envelope is persisted
- **GIVEN** the gateway validates a supported agent-spooled delivery frame
- **WHEN** it durably publishes the contained record
- **THEN** the JetStream body SHALL be byte-for-byte identical to
  `EdgeDeliveryFrameV1.record_bytes` and the common-spooled `EdgeRecordV1` bytes
- **AND** EventWriter SHALL recover contract, provenance, authorization, cost,
  semantic identity, and canonical content by decoding that binary body rather
  than an `Sr-Edge-*` header set
- **AND** delivery-only reauthorization or recovery MAY replace delivery-frame
  coordinates around those exact bytes but SHALL NOT rewrite the record,
  semantic digest, traffic class, or original collection proof

#### Scenario: Batch builder reaches its byte target
- **WHEN** adding another observation would move a frame past its byte target
- **THEN** the agent SHALL flush the current independently decodable frame
- **AND** item-count guards SHALL remain secondary to actual encoded size

#### Scenario: Unexpected record cannot fit
- **WHEN** one record violates the configured field or frame bounds
- **THEN** the producer SHALL quarantine it with a structured operator-visible
  error
- **AND** it SHALL NOT retry the same impossible frame indefinitely

#### Scenario: Compressed size declaration lies
- **WHEN** streaming decompression exceeds the independent output or expansion
  limit or does not equal the declared size
- **THEN** the consumer SHALL stop before unbounded allocation and classify the
  event as poison
- **AND** unsupported dictionaries, trailing frames, and excessive protobuf
  recursion SHALL be rejected

#### Scenario: Producer understates projected cost
- **WHEN** a producer submission supplies a route, traffic class, provenance, or
  projected database cost that differs from its effective grant
- **THEN** the agent sink SHALL ignore and replace non-authoritative metadata or
  reject the submission before spool acceptance
- **AND** the consumer SHALL verify the platform-stamped cost-model version and
  decoded worst-case cost before reserving destination capacity

### Requirement: Accepted dispositions mean durable JetStream acceptance
The agent SHALL retain each `EdgeRecordV1` byte string and its unresolved
delivery binding in a crash-safe local spool until the gateway reports a
disposition covering the corresponding `EdgeDeliveryFrameV1` lane sequence. The
gateway SHALL report an accepted disposition only after validating a JetStream
PubAck for the exact record digest/stable event ID and expected authoritative
stream. The finite platform-owned
route-profile/traffic-class lanes and recovery SHALL use independent spool/
credit sequences; lane identity SHALL NOT be keyed by output contract, payload
kind, or package. Spool-loss recovery SHALL use separately reserved
control capacity, so pressure or corruption in one lane cannot block the others.
An accepted edge disposition SHALL remain distinct from a local producer receipt:
the local receipt transfers retry ownership to the crash-safe agent spool, while
the edge disposition transfers the covered spool sequence to JetStream only
after authoritative PubAck.

#### Scenario: Local ownership transferred before edge durability
- **GIVEN** a local producer received a durable receipt after common-spool fsync
- **WHEN** the gateway cannot obtain an authoritative JetStream PubAck
- **THEN** the producer MAY release its private copy because the agent owns retry
- **AND** the agent SHALL retain the frame and the gateway SHALL withhold the edge
  accepted disposition

#### Scenario: JetStream is unavailable or full
- **GIVEN** the gateway cannot obtain a successful PubAck
- **WHEN** an agent has unacknowledged result frames
- **THEN** the gateway SHALL withhold acknowledgement
- **AND** the agent SHALL retain the frames and apply bounded backpressure or
  defer new work instead of dropping acknowledged data

#### Scenario: Edge acknowledgement is lost after PubAck
- **GIVEN** JetStream durably accepted a frame but the edge ACK was lost
- **WHEN** the agent reconnects and retries the same event
- **THEN** it SHALL reuse the same event ID, checksum, spool ID, and sequence
- **AND** broker and database idempotency SHALL prevent duplicate side effects

#### Scenario: Delivery coordinates are reused for different semantics
- **GIVEN** one network-scope/agent/lane/spool-ID/sequence delivery slot was
  durably bound to an event ID and semantic digest
- **WHEN** any sender reuses that slot for different semantics
- **THEN** the later claim SHALL be poison even if its broker publication ID is
  different
- **AND** legitimate recovery SHALL use new fenced delivery coordinates while
  retaining the original semantic event ID, digest, and traffic class

#### Scenario: Publish traverses a NATS leaf
- **GIVEN** the gateway connects through an edge NATS leaf or mirror that is not
  the configured durability authority
- **WHEN** the frame is forwarded toward the hub
- **THEN** local Core NATS acceptance SHALL NOT produce an accepted disposition
- **AND** the agent SHALL retain the frame until the authoritative stream's
  PubAck is observed

#### Scenario: Gateway restarts
- **WHEN** an agent-gateway restarts with result frames in flight
- **THEN** the agent SHALL resume from its retained spool
- **AND** correctness SHALL NOT depend on an in-memory gateway result queue

#### Scenario: Frame is permanently rejected
- **GIVEN** a bounded frame violates a permanent protocol rule
- **WHEN** safe rejection metadata is durably PubAcked to the authenticated
  installation's mapped audit/DLQ stream
- **THEN** the gateway SHALL return a rejected disposition
- **AND** the agent SHALL move the raw frame to durable local quarantine before
  reclaiming its spool sequence

#### Scenario: Local quarantine approaches its class reserve
- **GIVEN** rejected raw frames retain their immutable traffic class in a
  crash-safe local quarantine with per-class and aggregate byte quotas
- **WHEN** one class crosses its high-water threshold
- **THEN** the agent SHALL stop new affected producer/run admission and page operators
  before overwriting or silently expiring bytes
- **AND** bulk quarantine pressure SHALL NOT consume the interactive or recovery
  bookkeeping floor
- **AND** deletion or reclassification SHALL require an audited owner action,
  and re-enqueued unchanged bytes SHALL receive new fenced delivery coordinates
  without changing their semantic digest or traffic class

#### Scenario: One bulk producer is blocked
- **GIVEN** a sweep, MTR, inventory, plugin, or integration frame cannot be
  resolved in the shared bulk lane
- **WHEN** another producer and an interactive record are ready
- **THEN** byte-based fairness SHALL let other eligible bulk work and the
  independently reserved interactive lane progress within their limits
- **AND** no acknowledgement SHALL skip an unresolved sequence within its lane

#### Scenario: Persistence approaches retention expiry
- **GIVEN** an edge-ACKed event has not been projected
- **WHEN** its age approaches the supported outage plus catch-up safety boundary
- **THEN** operators SHALL be paged and new durable-record admission SHALL stop before
  capacity eviction
- **AND** expiry beyond the declared durability SLO SHALL leave affected
  executions or snapshots partial, preserve any prior current snapshot, record a
  continuous-source gap where applicable, and emit a critical incident

### Requirement: Traffic-class routing is immutable and physically disjoint
Every result SHALL carry exactly one control-plane-attested `traffic_class` of
`bulk` or `interactive`. All approved durable output contracts SHALL publish to
the fixed installation-local `telemetry.edge-record.v1.bulk.pNN` or
`telemetry.edge-record.v1.interactive.pNN` subjects for the initial
`durable-records-v1` route profile. The signed grant/capability, edge frame, semantic
digest, subject, expected-stream publish fence, and stream-map entry SHALL agree
on the class; a broker header SHALL NOT override the decoded binary envelope.
Bulk and interactive traffic SHALL use disjoint file-backed physical streams
and persistence durables, and replay, rollover, recovery, derived work, DLQ,
quarantine reclassification, and redrive SHALL preserve the original class.
Package, payload-kind, and output-contract count SHALL NOT create new lane,
subject, stream, consumer, connection, process, or RAFT-group cardinality.

#### Scenario: A producer attempts class promotion
- **GIVEN** a bulk assignment has a valid signed collection capability
- **WHEN** its frame, subject, stream-map entry, replay, or redrive claims the
  interactive class
- **THEN** the gateway or consumer SHALL reject the mismatch before consuming
  class-reserved capacity or producing side effects
- **AND** the event SHALL NOT consume the interactive stream, durable, claim
  queue, or database-credit floor

#### Scenario: Bulk physical stream is catching up
- **GIVEN** the bulk stream and durable contain a large retained backlog
- **WHEN** an admitted interactive result arrives
- **THEN** its disjoint interactive physical stream and durable SHALL remain
  reachable within the configured latency reservation
- **AND** overlapping filtered durables or subjects that give one message more
  than one authoritative ownership path SHALL fail readiness

#### Scenario: Stream-map version changes
- **WHEN** a logical partition moves to a new physical stream
- **THEN** admission SHALL stop behind a publish barrier until old gateway
  leases are revoked or expired and exactly one writable subject authority is
  active
- **AND** the sealed old durable SHALL remain restartable and drain through its
  AckWait, redelivery, repair, and rollback watermark
- **AND** every immutable historical map version, publisher fence, subject
  authority, and consumer configuration SHALL be retained until that watermark

### Requirement: Backpressure and fairness are bounded at every hop
Every transport and projection hop SHALL bound work by bytes and records. This
includes the agent sender, gateway publisher, JetStream consumer, derived-work
projector, and database writer. Admission, sending, publication, and derived
claim queues SHALL use byte-based weighted fairness across site or
`network_scope_id`, authenticated agent, producer assignment, run/execution,
and immutable traffic class.
Interactive work SHALL receive bounded reserved progress without bypassing
durability or starving bulk work. Per-scope, per-agent,
per-producer-assignment, per-run/execution, per-class,
and installation-wide backlog/drain-delay envelopes SHALL stop or defer new work
before a hot producer exhausts shared capacity.

#### Scenario: Consumer falls behind during active producer runs
- **GIVEN** durable consumer throughput drops below ingress throughput
- **WHEN** stream lag and agent spool pressure grow
- **THEN** bounded pull and publish windows SHALL propagate pressure toward the
  affected producer adapters
- **AND** lower-priority or overlapping runs SHALL be deferred before any
  unacknowledged record is overwritten

#### Scenario: Durable spool append fails
- **WHEN** reservation, append, fsync, or recovery encounters `ENOSPC`, `EIO`, or
  corrupt committed metadata
- **THEN** the agent SHALL stop opening affected producer windows/runs and SHALL
  NOT release the record as durable
- **AND** the run or continuous epoch SHALL pause or abort from reserved metadata
  capacity with an operator-visible failure

#### Scenario: A committed middle spool record is corrupt
- **GIVEN** later records in the same lane remain recoverable
- **WHEN** the agent cannot retransmit the corrupt sequence
- **THEN** it SHALL use reserved recovery capacity to open a new spool and send
  recovery-capability-bound bounded/chained loss manifest naming the abandoned/
  lost/uncertain scope without enumerating every recoverable tail event
- **AND** a durable rollover journal SHALL copy and fsync each recoverable segment
  plus old-to-new watermark before deleting that old segment, using reserved
  one-segment scratch and resuming idempotently after any crash
- **AND** every unresolved recoverable event SHALL retain semantic identity/body
  on the new spool even though its spool coordinates and broker ID change
- **AND** the recovery consumer SHALL wait for the complete terminal manifest,
  then commit loss audit, partial attempt/range state, fencing, and retry intent
  exactly once

#### Scenario: Recovery-control journal is corrupt
- **WHEN** the active recovery-control generation cannot reconstruct one committed
  record
- **THEN** a redundant journal and scheduler capability SHALL permit a fresh
  control generation to report the bounded prior loss without waiting on the
  corrupt sequence
- **AND** failure of both journal copies SHALL stop all durable producer admission
  and leave affected work to authoritative control-plane fencing rather than
  claim recovery

#### Scenario: Recovery state is durably applied
- **GIVEN** the complete immutable recovery manifest and all pages have been
  validated and the recovery consumer has committed loss audit,
  partialization/fencing, and retry intent
- **WHEN** the scheduler returns signed `RecoveryResolvedV1` bound to network
  scope, authenticated agent, recovery ID, manifest root, and applied state
- **THEN** the agent SHALL persist that resolution locally before garbage-
  collecting either journal copy or any manifest/page proof
- **AND** a lost resolution SHALL be safely recovered through an idempotent
  control query or replay
- **AND** recovery-stream PubAck alone SHALL NOT authorize journal garbage
  collection

#### Scenario: Large and small producer runs share a gateway
- **GIVEN** one million-target sweep or large inventory run and smaller
  interactive runs are active concurrently
- **WHEN** frames are selected for publication and processing
- **THEN** configured fair scheduling SHALL reserve pre-broker publication
  progress for the smaller executions
- **AND** the large run SHALL remain subject to per-scope, per-agent,
  per-producer-assignment, per-run, per-class, and installation byte/rate/backlog
  limits

#### Scenario: A database pull is admitted
- **WHEN** any persistence replica requests JetStream messages
- **THEN** it SHALL first reserve worst-case encoded/resident message bytes,
  projected write bytes and rows per requested message, plus active-transaction
  slots for concurrently executable aggregate transactions and commit-rate/fsync
  credits, from a fenced global destination grant
- **AND** after validation it SHALL refund only the unused delta while retaining
  actual credits through its bounded queue and final disposition

#### Scenario: A writer or credit holder crashes
- **GIVEN** source, graph, reconcile, recovery, DLQ, rollup, and repair writers
  share one result-pool limit with class and control progress reserves
- **WHEN** a holder crashes or replicas scale during a lease generation
- **THEN** its grant SHALL remain charged until surrendered or until it is both
  expired/fenced and its database transaction or session is confirmed terminated
- **AND** old/new overlap SHALL NOT exceed the hard limit
- **AND** new pulls SHALL stop when no valid grant can outlive the transaction
  deadline

### Requirement: Gateway routing identity is authoritative
The gateway SHALL derive installation trust, authenticated agent, gateway, and
permitted `network_scope_id`, traffic class, output-contract bundle/registry,
producer/package/assignment/run provenance, authorization context, execution,
and any source/coverage/target range from the canonical edge mTLS session plus a
locally verifiable control-plane-signed output grant and collection or delivery
capability. Scan ranges SHALL use scheduler authority; continuous, check,
command, and integration records SHALL use their explicit signed authorization
variant rather than fabricating a sweep range. Deployment CA
and certificate subject/CN identity SHALL be sufficient; SPIFFE metadata MAY be
accepted for compatibility but SHALL NOT be required. The gateway SHALL treat
corresponding payload fields only as correlation hints and SHALL reject outer-
envelope conflicts that could cross an agent, network-scope, class, assignment,
or stream boundary without a synchronous per-frame core or database lookup. The
consumer SHALL validate opaque-body membership before side effects.

#### Scenario: Payload attempts to spoof a network scope
- **GIVEN** an authenticated agent sends a frame containing a
  `network_scope_id` outside its signed capability
- **WHEN** the gateway validates the frame
- **THEN** it SHALL reject the frame without publishing it
- **AND** it SHALL emit an attributable security and protocol error

#### Scenario: Agent presents a stale assignment epoch
- **GIVEN** an execution shard or range has been fenced to a replacement agent
- **WHEN** the previous owner attempts new collection/publication using only its
  stale collection capability
- **THEN** the gateway SHALL reject it
- **AND** an exact immutable event/checksum/semantic-digest/traffic-class-bound
  delivery replay MAY publish only under an explicit delivery capability and
  SHALL remain fenced from authoritative state during reconciliation

#### Scenario: Agent claims a larger unsigned epoch
- **WHEN** an agent supplies an epoch not covered by a valid capability bound to
  its network scope, agent, execution, shard/range, immutable traffic class,
  generation, and expiry
- **THEN** the gateway SHALL reject it regardless of numeric value
- **AND** the consumer SHALL never select the highest observed epoch as authority

#### Scenario: Opaque records have mixed contract or authorization contexts
- **GIVEN** a frame declares one output contract, producer run, and authorization
  context
- **WHEN** decoding reveals a sweep, trace, inventory page, metric, or extension
  record from a different contract, producer assignment/run, traffic class,
  authorization epoch, source scope, or target range
- **THEN** the consumer SHALL reject the entire frame as poison before side
  effects
- **AND** producers SHALL flush a batch whenever contract, producer-run, or
  authorization context changes

#### Scenario: Decoded target is outside the signed range
- **GIVEN** the gateway validated the outer range ID/digest without decoding the
  protobuf body
- **WHEN** the consumer finds a decoded sweep target or MTR target outside the
  authoritative plan/range membership
- **THEN** it SHALL reject the event as poison before current-state, OCSF,
  execution, or trace side effects
- **AND** the opaque gateway validation SHALL NOT be treated as proof of body
  membership

#### Scenario: Valid spooled data outlives collection authority
- **GIVEN** a frame was durably spooled under a valid collection capability but
  delivery was delayed past expiry or a PubAck response was lost across a fence
- **WHEN** the scheduler issues a delivery-only capability bound to the original
  spool sequence, event/checksum/semantic digest, traffic class, collection
  proof, and range
- **THEN** the gateway MAY publish the unchanged event under that renewable
  delivery authority
- **AND** no new probe SHALL be started and the consumer SHALL still apply the
  authoritative attempt fence before state-changing effects

#### Scenario: Old valid observation drains after an outage
- **GIVEN** an immutable frame was collected within its signed collection
  interval and remained in agent spool or JetStream through a supported outage
- **WHEN** it is delivered much later through a gateway
- **THEN** the consumer SHALL validate it against the original collection
  interval/attested clock tolerance rather than a symmetric receipt-age window
- **AND** gateway receipt time SHALL record delivery latency without making the
  old observation poison

#### Scenario: Observation attempts to pin future state
- **WHEN** an observation timestamp falls outside its signed collection interval
  or exceeds the permitted attested future tolerance
- **THEN** the consumer SHALL quarantine it before current-state effects
- **AND** a renewed delivery capability SHALL NOT alter that collection-time
  decision

### Requirement: Replay is idempotent and poison data is durable
Each consumer SHALL apply independently decodable events using an ingest ledger,
stable domain keys, and deterministic derived-event identifiers. It MAY group
multiple already validated messages into one aggregate byte/row/time-bounded
transaction, but every message SHALL retain an independent ledger/slot result and
receive an explicit JetStream ACK only after the containing transaction commits;
`AckAll` SHALL NOT be used. Permanently invalid data SHALL be copied to a durable
DLQ before the source delivery is terminated. The canonical DLQ wrapper SHALL
retain the exact original `EdgeRecordV1` bytes and digest without reconstructing
semantic fields from broker headers. It SHALL add only bounded DLQ/source
placement metadata including original delivery coordinates, source stream/
sequence, applicable delivery-proof audit, and error classification. DLQ
`MaxAge` SHALL be disabled;
raw records SHALL leave the stream only through catalog-backed, state-aware,
audited deletion.

#### Scenario: Event is delivered repeatedly
- **WHEN** an event with the same stable event ID and checksum is delivered more
  than once
- **THEN** the consumer SHALL commit its domain and derived side effects at most
  once
- **AND** execution/snapshot counts and current state SHALL be reconciled from
  unique domain records rather than incremented per delivery

#### Scenario: Concurrent workers complete out of delivery order
- **GIVEN** a later JetStream delivery commits while an earlier worker has not
  committed or crashes
- **WHEN** acknowledgements are sent
- **THEN** only the committed delivery SHALL receive its individual explicit ACK
- **AND** the earlier delivery SHALL remain eligible for idempotent redelivery

#### Scenario: Event ID is reused for different semantics
- **WHEN** a committed event ID is received with a different body checksum or
  immutable output-contract/registry/schema/size/cost/traffic-class/producer-run/
  execution/epoch/authorization/range envelope
- **THEN** the consumer SHALL classify it as poison
- **AND** it SHALL durably publish the original bytes and diagnostics to the DLQ
  before terminating the source delivery

#### Scenario: Transient database outage persists
- **WHEN** database failure continues through repeated deliveries
- **THEN** the persistence consumer SHALL pause pulls or retry indefinitely with
  bounded backoff
- **AND** it SHALL NOT exhaust a finite delivery count into TERM or poison DLQ

#### Scenario: Decoder rollout poisons ordinary fleet traffic
- **WHEN** per-physical-shard, per-traffic-class, or aggregate poison rate/ratio
  crosses its configured systemic threshold
- **THEN** source pulls and new affected gateway acceptance SHALL pause before
  the separately class-reserved DLQ or agent quarantine reaches capacity
- **AND** events without a DLQ PubAck SHALL remain unresolved rather than TERM
- **AND** bulk poison SHALL NOT consume the interactive DLQ/quarantine floor or
  the independent recovery-control reserve

#### Scenario: DLQ record is cataloged
- **WHEN** a durable DLQ message is indexed
- **THEN** an idempotent `result_dlq_record` SHALL bind its stable DLQ ID and
  physical stream/sequence to immutable scope, authenticated agent, source
  provenance, semantic digest, traffic class, error cohort, redrive history,
  audit actor/time, waiver, and final state
- **AND** unknown or unindexed stream sequences SHALL NOT be guessed, purged, or
  treated as resolved

#### Scenario: Operator requests final DLQ deletion
- **GIVEN** a catalog entry is durably `resolved`, `redriven`, or `waived`
- **WHEN** an authorized deleter evaluates its stream sequence
- **THEN** deletion SHALL occur only after the dependent semantic-ledger and
  audit safe-deletion watermark is closed
- **AND** an unresolved catalog entry or unknown dependency SHALL retain its raw
  record without time-based expiry

#### Scenario: Operators redrive a repaired poison cohort
- **GIVEN** retained raw DLQ bytes were rejected by a now-fixed decoder
- **WHEN** an installation-authorized operator selects an exact error cohort and
  rate-limits an audited redrive
- **THEN** the system SHALL republish through the current stream map with the
  original trusted network scope, authenticated agent, producer/contract and
  collection provenance, semantic digest, content, and traffic class
- **AND** each attempt SHALL use a durable synthetic `dlq-redrive` lane,
  monotonic sequence, fresh delivery/map envelope, and a capability bound to the
  immutable catalog record, thereby creating a new delivery-slot binding
- **AND** the ingest ledger SHALL make already committed events harmless while
  original spool/stream coordinates remain immutable provenance only

#### Scenario: Consumer has not deployed a valid newer schema
- **WHEN** an event uses a valid advertised schema but its mapped consumer is not
  ready
- **THEN** readiness/admission and pulls SHALL pause as a deployment failure
- **AND** the event SHALL NOT be permanently classified as poison

### Requirement: Bounded durable outputs remain stream records
Bounded durable outputs SHALL remain independently decodable JetStream records,
including observations, traces, inventory pages/manifests, metrics, findings,
events, and approved extension records. An oversize logical output SHALL be split only by its approved
canonical paging/batching contract or rejected/quarantined. This change SHALL
NOT add an Object Store fallback for oversize record bytes; the record plane MAY
carry only bounded artifact references and lifecycle metadata.

#### Scenario: Full MTR trace fits the bounded contract
- **WHEN** a normal enriched trace satisfies the configured hop, path, label,
  string, and byte bounds
- **THEN** it SHALL be published as a typed MTR trace event
- **AND** consumers SHALL NOT fetch an object before processing it

#### Scenario: Durable output exceeds the event contract
- **WHEN** a sweep, trace, inventory, metric, finding, event, or extension record
  exceeds its byte or projected-row budget and has no valid paging boundary
- **THEN** it SHALL be rejected or quarantined according to the record protocol
- **AND** it SHALL NOT be silently diverted into Object Store

### Requirement: Migration requires a minimum edge-record version and hard cutover
Before cutover, the control plane and gateways SHALL enforce a minimum agent/
gateway version that can send, retain, replay, and drain v1 frames for the
selected contract registry. Older binaries SHALL stop receiving affected work
and SHALL be upgraded; this change SHALL NOT add a patched legacy JSON sender,
unpatched-agent bridge, or compatibility stream. New v1 emission SHALL require
the `edge-records:v1` gateway capability, exact downstream registry readiness,
and explicit cohort configuration; a configuration hash SHALL NOT select a
result format.

Each cohort SHALL cross one ingress-epoch barrier. The barrier SHALL stop new
legacy producer runs before enabling v1 assignments. Only identified records
accepted before the barrier MAY drain through an existing legacy consumer. A
run SHALL NOT dual-write authoritative legacy and v1 output. Rollback SHALL stop
new affected work and retain compatible v1 spool/stream consumers; it SHALL NOT
start new legacy emission.

Historical network-scope and identity backfill SHALL run online and idempotently
behind a durable CDC cursor and source high-water marks. Post-water legacy writes
SHALL be captured and continuously applied during the historical pass. A hard
delta byte/age budget SHALL slow or stop new legacy scan admission before capture
can overflow, and cutover SHALL wait until only a configured bounded tail remains.
The final ingress-epoch barrier SHALL fence/drain old writers, drain and validate
only the bounded captured delta, and flip authority. It SHALL NOT scan or rewrite
unbounded retained history while new scan admission is stopped.

#### Scenario: Registered binary is below the minimum version
- **WHEN** the control plane or gateway observes an agent that cannot emit v1
  records or read and drain retained v1 spool state for the selected registry
- **THEN** it SHALL stop assigning new durable-record-producing work to that binary
- **AND** cutover readiness SHALL fail until upgrade rather than route it through
  a legacy sender or compatibility bridge

#### Scenario: Cohort crosses the ingress barrier
- **GIVEN** every agent/gateway in the cohort and every downstream route/projector
  is ready for the exact v1 registry
- **WHEN** the control plane closes the cohort's old ingress epoch
- **THEN** it SHALL stop new old-path runs before enabling v1 assignments
- **AND** only identified pre-barrier backlog MAY drain without authorizing any
  new legacy output

#### Scenario: A plugin, add-on, or integration output contract cuts over
- **WHEN** a durable binary contract and its agent, gateway, registry, JetStream,
  and EventWriter path reach declared parity
- **THEN** new runs SHALL stop emitting the same persistent facts through
  `plugin_result`, lossy telemetry, broker-free sync, or direct persistence
- **AND** the old adapter MAY remain only for bounded status or draining
  identified pre-cutover backlog without dual authoritative emission

#### Scenario: Historical backfill is larger than the cutover window
- **GIVEN** retained history cannot be rewritten within the bounded admission
  pause objective
- **WHEN** migration prepares the new identities and scope bindings
- **THEN** it SHALL backfill online to a durable high-water while capturing
  and continuously applying concurrent legacy writes through a durable CDC cursor
- **AND** admission SHALL stop before the delta byte/age bound is exhausted
- **AND** cutover SHALL wait for historical parity before opening the short
  barrier and SHALL drain only the final bounded delta inside it

#### Scenario: Rollout is disabled
- **WHEN** operators disable a cohort after v1 cutover
- **THEN** new affected producer work SHALL stop and existing v1 spool lanes
  SHALL continue through a compatible sender until drained
- **AND** no agent binary unable to read the retained spool version SHALL be
  deployed
- **AND** rollback SHALL NOT select or generate new legacy JSON output

#### Scenario: Legacy path is retired
- **WHEN** all registered agents meet the minimum version, the supported offline
  upgrade window has elapsed, and all identified pre-cutover and v1 backlog is
  drained
- **THEN** removal of legacy emission and decode MAY proceed in a separately
  gated release
