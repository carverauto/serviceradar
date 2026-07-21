# edge-architecture Delta

## RENAMED Requirements

- FROM: `### Requirement: Results ingestion uses gRPC/ERTS routing`
- TO: `### Requirement: Results ingestion uses layered gRPC and JetStream routing`

## MODIFIED Requirements

### Requirement: Results ingestion uses layered gRPC and JetStream routing
The system SHALL choose result routing by workload semantics. Sync snapshots
SHALL retain the existing chunked gRPC-to-core path. High-volume agent-originated
sweep and MTR observations SHALL enter through an authenticated, flow-controlled
gRPC stream at the agent-gateway and SHALL be durably published by the gateway
to JetStream before the edge delivery is acknowledged. ERTS SHALL remain an
internal control and low-volume status transport and SHALL NOT be the durable
bulk-observation boundary.

#### Scenario: Sync results retain broker-free ingestion
- **GIVEN** an agent emits a sync result that exceeds single-message limits
- **WHEN** the agent streams it through the existing sync results method
- **THEN** the agent-gateway SHALL forward it through the standard sync pipeline
  to the sync ingestor
- **AND** no JetStream requirement SHALL be introduced for that snapshot

#### Scenario: Sweep observations use layered delivery
- **GIVEN** an authenticated agent produces a sweep observation frame
- **WHEN** it sends the frame through the result stream
- **THEN** the gateway SHALL publish it to the installation-local sweep stream
  selected by its immutable scheduler-signed `traffic_class`
- **AND** bulk and interactive sweep results SHALL use disjoint physical streams
  and durable consumers
- **AND** SHALL return an accepted disposition only after a successful
  authoritative JetStream PubAck
- **AND** core persistence SHALL occur through the event-writer consumer

#### Scenario: MTR traces use an independent durable lane
- **GIVEN** an authenticated agent produces a complete MTR trace
- **WHEN** it sends the typed trace frame through the result stream
- **THEN** the gateway SHALL publish it to the installation-local MTR stream
  selected by its immutable scheduler-signed `traffic_class`
- **AND** bulk and interactive MTR results SHALL use disjoint physical streams
  and durable consumers
- **AND** sweep reachability traffic SHALL remain isolated from trace backlog

#### Scenario: Patched bounded legacy result is received during migration
- **GIVEN** the agent and gateway satisfy the minimum dual-path version
- **WHEN** a patched agent uses the selected legacy results RPC
- **THEN** it SHALL send one stable bounded JSON chunk per independently
  acknowledged request rather than one cumulative request containing all chunks
- **AND** the gateway SHALL wrap that chunk in a complete broker envelope,
  publish it to the typed result stream, and wait for PubAck before acknowledging
- **AND** SHALL NOT use ERTS/direct persistence as the authoritative fallback

#### Scenario: Agent is below the dual-path minimum
- **WHEN** an agent cannot send independently acknowledged bounded legacy frames
  and cannot send v1 frames
- **THEN** the scheduler SHALL assign no new sweep or MTR execution to it
- **AND** SHALL require upgrade rather than provide an unpatched compatibility
  bridge

#### Scenario: Control and small status remain direct
- **GIVEN** an agent sends configuration, command response, heartbeat, or other
  bounded non-persistent status
- **WHEN** the gateway receives it
- **THEN** the existing gRPC/ERTS control route MAY be used
- **AND** that response SHALL NOT be treated as durable observation ingestion

### Requirement: Results routing is explicit by result type
The result pipeline SHALL route sync snapshots, patched bounded-legacy results,
versioned sweep observation batches, sweep execution events, versioned MTR trace
batches, and spool-loss recovery tombstones by explicit payload kind, schema
version, authoritative `network_scope_id`, agent, execution, and immutable
scheduler-signed traffic class. It SHALL NOT use content sniffing,
source-string ambiguity, unsigned caller priority, or one generic status handler
for these types.

#### Scenario: Versioned observation selects its stream and consumer
- **GIVEN** the gateway receives a supported edge result frame
- **WHEN** it validates the declared payload kind and schema version
- **THEN** it SHALL select the map-versioned expected physical stream and
  versioned subject for the signed traffic class
- **AND** persist kind, version, compression, sizes, checksum, sequence, and
  network-scope/agent/execution/class routing and stream-map metadata in the
  canonical broker-header envelope
- **AND** the corresponding typed consumer SHALL decode and project it without
  content sniffing

#### Scenario: Sync result selects the sync handler
- **GIVEN** core receives a payload explicitly tagged as `sync`
- **WHEN** the results pipeline processes it
- **THEN** it SHALL dispatch to the sync ingestor
- **AND** SHALL NOT route it to a telemetry stream by inspecting its bytes

#### Scenario: Payload kind or version is permanently unsupported
- **WHEN** an edge frame declares an invalid or unadvertised payload kind or
  schema version
- **THEN** the gateway SHALL return a structured permanent rejection without
  publishing the payload
- **AND** the agent SHALL quarantine the frame with its original traffic class
  and expose an operator alert

#### Scenario: Advertised schema is temporarily not ready downstream
- **GIVEN** an edge schema/version is valid and advertised by the deployment
- **WHEN** its mapped stream or compatible consumer is not ready
- **THEN** gateway readiness and new assignment admission SHALL fail or pause
- **AND** an already-spooled frame SHALL remain retryable rather than be
  classified as poison or permanently quarantined

#### Scenario: Signed spool-loss tombstone is routed
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
- **AND** MAY accept an exact immutable event/checksum-bound replay only with a
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

## ADDED Requirements

### Requirement: Result stream flow control has application semantics
The edge result RPCs SHALL use bounded bidirectional streaming with cumulative
application dispositions over persistent `sweep-bulk`, `sweep-interactive`,
`mtr-bulk`, `mtr-interactive`, and recovery spool sequences. Bulk and interactive
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
- **AND** scanning admission SHALL react before the spool can overwrite
  unacknowledged data

#### Scenario: Cumulative acknowledgement has a gap
- **GIVEN** a later frame obtains PubAck while an earlier sequence has not
- **WHEN** the gateway computes its response
- **THEN** it SHALL acknowledge only the highest contiguous PubAcked sequence
- **AND** the missing sequence SHALL remain eligible for retry

#### Scenario: Bulk publication is blocked
- **GIVEN** a bulk MTR or sweep spool sequence cannot advance
- **WHEN** interactive results are available on their independently budgeted
  lane
- **THEN** the gateway SHALL continue accepting interactive work within its
  bounded credits and class-specific quota
- **AND** bulk backlog SHALL NOT consume the interactive HTTP/2 connection,
  gateway publisher connection, stream, or durable consumer

#### Scenario: Lane reconnects to a replacement gateway
- **WHEN** an agent opens a new result session
- **THEN** it SHALL declare lane, spool ID, sequence base, first unresolved
  sequence, fresh nonce, and requested credits
- **AND** SHALL ignore dispositions that do not match its active nonce and spool

### Requirement: Gateways remain replaceable on the result path
The correctness chain SHALL keep unacknowledged durable state in the agent spool
and acknowledged durable state in JetStream. A gateway SHALL NOT require a
persistent result volume or volatile fallback queue to prevent data loss.

#### Scenario: Gateway is replaced during a large sweep
- **WHEN** the connected gateway disappears after receiving unacknowledged
  frames
- **THEN** the agent SHALL reconnect and replay those frames with their original
  IDs, sequences, network scope, execution, and traffic class
- **AND** the replacement gateway SHALL resume publishing without recovering
  private state from the prior gateway
