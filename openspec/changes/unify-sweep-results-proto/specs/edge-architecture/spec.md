# edge-architecture Delta

## RENAMED Requirements

- FROM: `### Requirement: Results ingestion uses gRPC/ERTS routing`
- TO: `### Requirement: Results ingestion uses layered gRPC and JetStream routing`
- FROM: `### Requirement: Results routing is explicit by result type`
- TO: `### Requirement: Results routing is explicit by output contract`

## MODIFIED Requirements

### Requirement: Results ingestion uses layered gRPC and JetStream routing
The system SHALL choose result routing by workload semantics. Persistent
agent-originated observations, telemetry, inventory, findings, traces, events,
and approved extension records SHALL enter through an authenticated,
flow-controlled gRPC stream at the agent-gateway and SHALL be durably published
by the gateway to JetStream before edge delivery is acknowledged. The existing
sync gRPC-to-core route MAY drain only already-accepted pre-cutover backlog; new
or migrated persistent integration output SHALL use the durable record plane.
ERTS SHALL remain an internal command/control and bounded status transport and
SHALL NOT be a durable bulk-record boundary.

#### Scenario: Pre-cutover legacy sync backlog drains
- **GIVEN** bounded legacy sync chunks were accepted before a cohort's hard
  edge-record cutover
- **WHEN** the cohort begins v1 producer assignments
- **THEN** the existing sync ingestor MAY drain only that identified backlog
- **AND** rollback SHALL disable new affected work and retain compatible v1
  consumers rather than generate new legacy output

#### Scenario: Sweep observations use layered delivery
- **GIVEN** an authenticated agent produces a sweep observation frame
- **WHEN** it sends the frame through the record stream
- **THEN** the gateway SHALL publish it to the fixed installation-local edge
  record subject selected by its platform route profile and immutable
  scheduler-signed `traffic_class`
- **AND** bulk and interactive sweep results SHALL use disjoint physical streams
  and durable consumers
- **AND** SHALL return an accepted disposition only after a successful
  authoritative JetStream PubAck
- **AND** core persistence SHALL occur through the event-writer consumer

#### Scenario: MTR traces share finite durable lanes fairly
- **GIVEN** an authenticated agent produces a complete MTR trace
- **WHEN** it sends the typed trace frame through the record stream
- **THEN** the gateway SHALL publish it to the same finite platform-owned edge
  record route selected by its immutable scheduler-signed `traffic_class`
- **AND** byte-based producer/run fairness plus disjoint bulk/interactive
  physical streams SHALL prevent trace backlog from monopolizing other records

#### Scenario: Plugin or integration publishes persistent output
- **GIVEN** an assignment grants a Wasm, native add-on, or embedded integration
  an approved durable output contract
- **WHEN** its bounded record is fsynced in the common spool and reaches the
  gateway
- **THEN** the gateway SHALL publish it through the fixed edge-record route and
  wait for authoritative PubAck
- **AND** the output SHALL NOT use `plugin_result`, lossy telemetry, ERTS, or
  direct CNPG as an alternate persistent path

#### Scenario: Agent is below the edge-record minimum
- **WHEN** an agent or reachable gateway cannot send, retain, and drain the
  required v1 edge-record protocol and pinned contract bundle
- **THEN** the control plane SHALL assign no new affected durable producer run
  through that path
- **AND** SHALL require upgrade rather than provide a legacy JSON sender or
  compatibility bridge

#### Scenario: Control and small status remain direct
- **GIVEN** an agent sends configuration, command response, heartbeat, or other
  bounded non-persistent status
- **WHEN** the gateway receives it
- **THEN** the existing gRPC/ERTS control route MAY be used
- **AND** that response SHALL NOT be treated as durable observation ingestion

### Requirement: Results routing is explicit by output contract
The durable result pipeline SHALL route typed platform records, approved
extension records, and spool-loss recovery tombstones
by exact output-contract bundle/registry epoch, finite platform route profile,
schema version, authoritative `network_scope_id`, authenticated agent and
producer/package/assignment/run context, and immutable control-plane-attested traffic
class. Platform payload family MAY select a compiled decoder family but SHALL
NOT allocate infrastructure per package contract. The pipeline SHALL NOT use
content sniffing, source-string ambiguity, unsigned caller priority,
package-selected subjects, or one generic status handler for persistent data.

#### Scenario: Versioned record selects its route and projector
- **GIVEN** the gateway receives a supported `EdgeDeliveryFrameV1` containing a
  valid `EdgeRecordV1`
- **WHEN** it validates the exact output contract, registry, platform family,
  route profile, and schema version
- **THEN** it SHALL select the map-versioned expected physical stream and
  versioned subject for the signed traffic class
- **AND** publish the exact `EdgeRecordV1` bytes from the delivery frame without
  re-encoding or copying semantic fields into broker headers
- **AND** the corresponding typed consumer SHALL decode the binary record body
  and project it without content sniffing

#### Scenario: Inventory result selects the approved projector
- **GIVEN** EventWriter receives a typed inventory page inside a validated
  `EdgeRecordV1`
- **WHEN** the result pipeline processes it
- **THEN** it SHALL dispatch to the installed DIRE-aware inventory projector by
  exact contract bundle
- **AND** SHALL NOT route it by content sniffing or a package-selected subject

#### Scenario: Output contract or version is permanently unsupported
- **WHEN** an `EdgeRecordV1` declares an invalid, unapproved, or unadvertised
  contract bundle or schema version
- **THEN** the gateway SHALL return a structured permanent rejection without
  publishing the payload
- **AND** the agent SHALL quarantine the frame with its original traffic class
  and expose an operator alert

#### Scenario: Advertised contract is temporarily not ready downstream
- **GIVEN** an exact contract bundle is valid and advertised by the deployment
- **WHEN** its mapped stream or compatible consumer is not ready
- **THEN** gateway readiness and new assignment admission SHALL fail or pause
- **AND** an already-spooled frame SHALL remain retryable rather than be
  classified as poison or permanently quarantined

#### Scenario: Journalled spool-loss tombstone is routed
- **WHEN** a recovery-capability-bound tombstone arrives on the reserved control
  lane
- **THEN** the gateway SHALL publish it to the installation-local
  result-recovery stream with the original traffic class preserved
- **AND** its scheduler-repair consumer SHALL be distinct from poison-DLQ
  handling
- **AND** the recovery PubAck SHALL stop publication retry but SHALL NOT
  authorize local recovery-journal garbage collection
- **AND** the agent SHALL retain the journal until it durably records a signed
  `RecoveryResolvedV1` or an idempotent query confirms the scheduler-repair
  consumer transaction committed the recovery manifest

#### Scenario: Execution assignment is stale
- **GIVEN** the scheduler has issued a newer fenced assignment epoch for a shard
- **WHEN** an older owner submits a frame under stale collection authority
- **THEN** explicit routing SHALL reject new collection/publication
- **AND** MAY accept an exact immutable event-ID/`record_sha256`-bound delivery replay only with a
  freshly authorized delivery-only capability preserving its original class
- **AND** delivery-only replay SHALL NOT restore domain eligibility or let the
  old event race the replacement's authoritative state
- **AND** authority SHALL come from a locally verified signed assignment and
  propagated fence generation, never the largest agent-supplied epoch

#### Scenario: Result enters quarantine, DLQ, or redrive
- **WHEN** a result is quarantined, moved to a poison DLQ, or authorized for
  redrive
- **THEN** its original signed traffic class SHALL remain in its envelope and
  audit identity
- **AND** redrive SHALL target the same class-specific stream and durable
  consumer and SHALL NOT promote bulk work into an interactive path

### Requirement: Sysmon Metrics Ingestion
Persistent sysmon metrics pushed over gRPC SHALL use the canonical metric output
contract through the agent-owned durable sink, gateway PubAck boundary, and
EventWriter. Bounded coalescible sysmon health MAY remain status, but Core SHALL
NOT write persistent CPU, CPU-cluster, memory, disk, or process samples received
from `GatewayServiceStatus` directly to CNPG.

#### Scenario: Sysmon metrics forwarded to core
- **WHEN** an edge agent emits persistent sysmon metrics
- **AND** the agent sink accepts bounded canonical metric records
- **THEN** the gateway SHALL publish them to the fixed edge-record subject and
  wait for authoritative JetStream PubAck
- **AND** EventWriter SHALL be the sole writer of their CNPG hypertable rows

#### Scenario: Sysmon payload size tolerance
- **WHEN** one sysmon collection interval exceeds one edge-record frame
- **THEN** the agent SHALL split it at canonical record boundaries within the
  output-contract and the frozen `MaxFrameBytes` bound
- **AND** an individually oversize sample SHALL be rejected explicitly rather
  than accepted through a larger status-message exception

### Requirement: Sysmon metrics ingestion via gRPC
The system SHALL carry persistent sysmon metrics over the authenticated gRPC
edge-record transport, durably publish the canonical metric contract to
JetStream before edge acknowledgement, and persist it into the installation
CNPG hypertables only through EventWriter. `GatewayServiceStatus` MAY retain
bounded coalescible sysmon health during migration but SHALL NOT remain a direct
Core-to-CNPG metric path.

#### Scenario: Sysmon metrics persisted for the agent device
- **GIVEN** an agent produces a bounded canonical sysmon metric record
- **WHEN** the gateway obtains an authoritative JetStream PubAck
- **THEN** EventWriter SHALL resolve the authenticated agent's device identifier
- **AND** SHALL idempotently insert the metrics into the installation hypertables
  without a direct status-to-database write

#### Scenario: Device mapping unavailable
- **GIVEN** an accepted sysmon metric record has no linked device record
- **WHEN** EventWriter projects the record
- **THEN** it SHALL apply the approved nullable/fallback identity policy or
  retain the record for bounded repair
- **AND** SHALL NOT invent another agent/source identity from payload claims

### Requirement: Sysmon payload size handling
The agent SHALL split persistent sysmon samples into independently decodable
canonical metric records within the output-contract and the frozen
`MaxFrameBytes` bound.
The gateway SHALL publish each accepted `EdgeRecordV1` byte-for-byte unchanged
and SHALL NOT
truncate, whole-run materialize, or silently divert an oversize payload.

#### Scenario: Large sysmon payload
- **GIVEN** one collection interval produces more sysmon data than one frame can
  hold
- **WHEN** the agent builds its metric output
- **THEN** it SHALL emit multiple independently bounded records under the same
  run/epoch context
- **AND** each record SHALL transfer ownership and receive edge acknowledgement
  independently

### Requirement: Mapper discovery results ingestion via gRPC
Mapper discovery results SHALL be submitted by agents to the gateway through
the authenticated gRPC edge-record transport as bounded typed inventory records
and SHALL be durably published to JetStream before edge acknowledgement. The
gateway SHALL NOT require a standalone mapper service and SHALL NOT route new
persistent mapper datasets through generic status, ERTS, or direct core/database
ingestion.

#### Scenario: Agent pushes mapper discovery results
- **GIVEN** an agent produces mapper discovery pages during a job
- **WHEN** each bounded page is accepted by the common durable producer sink
- **THEN** the gateway SHALL publish the canonical inventory record to the fixed
  edge-record route and wait for authoritative PubAck
- **AND** EventWriter SHALL ingest the page through the DIRE-aware inventory
  projector without waiting for the whole job to materialize

#### Scenario: Mapper results routing is explicit
- **GIVEN** EventWriter receives a mapper inventory page or terminal manifest
- **WHEN** the result pipeline decodes the trusted output-contract fields from
  `EdgeRecordV1`
- **THEN** it SHALL dispatch to the exact approved mapper/inventory projector
- **AND** results SHALL NOT be treated as generic status updates or routed by
  content sniffing

## ADDED Requirements

### Requirement: Record stream flow control has application semantics
The edge record RPCs SHALL use bounded bidirectional streaming with cumulative
application dispositions over the finite platform-owned route-profile/class and
recovery spool sequences. Lane identity SHALL NOT be keyed by output contract,
payload kind, or package. Bulk and interactive
lanes SHALL have disjoint physical streams and durable consumers. Every lane
SHALL have an independent RPC, and bulk, interactive, and recovery SHALL use
separately pooled HTTP/2 connections with reserved connection-level windows.
Transport-level write completion or HTTP/2 flow-control progress SHALL NOT be
interpreted as durable acceptance.

#### Scenario: Receiver pressure closes the send window
- **GIVEN** the configured in-flight byte or frame window is full
- **WHEN** additional agent frames are ready
- **THEN** the sender SHALL retain them in its disk spool and stop advancing the
  application window
- **AND** affected producer admission SHALL react before the spool can overwrite
  unacknowledged data

#### Scenario: Cumulative acknowledgement has a gap
- **GIVEN** a later frame obtains PubAck while an earlier sequence has not
- **WHEN** the gateway computes its response
- **THEN** it SHALL acknowledge only the highest contiguous PubAcked sequence
- **AND** the missing sequence SHALL remain eligible for retry

#### Scenario: Bulk publication is blocked
- **GIVEN** a bulk sweep, trace, inventory, plugin, or integration spool
  sequence cannot advance
- **WHEN** interactive results are available on their independently budgeted
  lane
- **THEN** the gateway SHALL continue accepting interactive work within its
  bounded credits and class-specific quota
- **AND** bulk backlog SHALL NOT consume the interactive HTTP/2 connection,
  gateway publisher connection, stream, or durable consumer

#### Scenario: Lane reconnects to a replacement gateway
- **WHEN** an agent opens a new record session
- **THEN** it SHALL declare spool ID, sequence base, first unresolved
  sequence, fresh nonce, and requested credits
- **AND** SHALL ignore dispositions that do not match its active nonce and spool

### Requirement: Gateway disposition evidence retention is bounded and replay-safe
A gateway SHALL NOT evict volatile per-sequence terminal-disposition evidence
unless it has successfully written an ordered cumulative `EdgeDeliveryAckV1`
covering those sequences and the same validated idempotent publication path can
reproduce the terminal disposition and authoritative PubAck after ACK loss,
duplicate replay, or reconnect, without subscribing to stored records or
recovering private gateway state.
Retained gateway disposition evidence SHALL have a documented bound independent
of total lane lifetime. Reporting or evicting gateway evidence SHALL NOT advance
the agent-local reclaim watermark or authorize spool deletion.

#### Scenario: Written cumulative acknowledgement is lost
- **GIVEN** the gateway has written a cumulative acknowledgement and evicted the
  covered volatile disposition evidence
- **WHEN** the agent does not observe that acknowledgement and replays the same
  immutable slot from its first unresolved sequence
- **THEN** the gateway SHALL idempotently repeat the required publication and
  validated PubAck path to reproduce the same terminal disposition
- **AND** SHALL rebuild the contiguous resolved prefix without an ambiguous
  result caused solely by evidence eviction

#### Scenario: Long-lived lane bounds retained evidence
- **GIVEN** a lane continues resolving frames beyond every configured in-flight
  window
- **WHEN** ordered cumulative acknowledgements are successfully written
- **THEN** retained gateway disposition evidence SHALL remain within its
  documented frame-and-byte bound
- **AND** the bound SHALL NOT grow with the total number of frames processed by
  the lane

#### Scenario: Retryable gap applies bounded backpressure
- **GIVEN** an earlier sequence remains retryable or unresolved while later
  publications obtain terminal PubAcks
- **WHEN** the contiguous acknowledgement cannot cover those later outcomes
- **THEN** the gateway SHALL apply lane-local backpressure before retained
  disposition evidence exceeds its documented frame-and-byte bound
- **AND** SHALL NOT cross the gap or discard evidence that the idempotent
  publication and validated PubAck path cannot reproduce

### Requirement: Gateways remain replaceable on the result path
The correctness chain SHALL keep unacknowledged durable state in the agent spool
and acknowledged durable state in JetStream. A gateway SHALL NOT require a
persistent result volume or volatile fallback queue to prevent data loss.

#### Scenario: Gateway is replaced during a large producer run
- **WHEN** the connected gateway disappears after receiving unacknowledged
  frames
- **THEN** the agent SHALL reconnect and replay those frames with their original
  IDs, sequences, network scope, producer/run context, and traffic class
- **AND** the replacement gateway SHALL resume publishing without recovering
  private state from the prior gateway

> `MaxRecordBytes` bounds one `EdgeRecordV1` and `MaxFrameBytes` bounds one
> `EdgeDeliveryFrameV1`. Their values are frozen by the edge record v1 wire ABI and
> are deliberately NOT restated here; cite the symbols.
