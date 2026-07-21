# mtr-diagnostics Delta

## MODIFIED Requirements

### Requirement: On-Demand MTR Execution
The agent SHALL support on-demand MTR execution through the ControlStream command
interface. ControlStream SHALL return bounded command/progress state and a stable
trace identifier; the complete enriched trace SHALL use the same canonical
durable MTR event contract as scheduled, sweep-profile, and ad-hoc traces while
remaining in its scheduler-attested immutable traffic-class lane.

#### Scenario: On-demand trace succeeds
- **WHEN** an authorized `mtr.run` command is received with a target address
- **THEN** the agent SHALL execute one bounded MTR trace and assign a stable
  trace ID correlated to the command
- **AND** the command response SHALL report accepted/progress/terminal state and
  the trace ID
- **AND** the complete ASN, DNS, MPLS, ECMP, hop, reachability, and timing result
  SHALL be published through `MtrTraceBatchV1`
- **AND** an on-demand trace classified as interactive SHALL use the dedicated
  interactive MTR spool, subject, physical stream, durable, and result credits

#### Scenario: Caller waits for an interactive result
- **GIVEN** the trace completes within the command's bounded response window
- **WHEN** the terminal response is returned
- **THEN** it MAY contain a bounded display summary
- **AND** durable persistence and downstream processing SHALL still use the
  canonical MTR event rather than a direct core/database write

### Requirement: Result Reporting
All MTR producers SHALL report complete traces as versioned, lossless,
byte-bounded `MtrTraceBatchV1` protobuf events through the edge result stream.
The sweep host observation MAY carry only a small reachability summary and
stable trace ID. The gateway SHALL publish complete traces to the dedicated MTR
JetStream stream selected by immutable signed `traffic_class` before
acknowledging them. Every batch SHALL have one authoritative
`network_scope_id`, authenticated agent, source/authorization context, and
traffic class; every decoded trace SHALL match that envelope before side effects.
Every producer SHALL feed each completed trace directly into a bounded byte/row/
write-cost/timer builder and durable spool, then release the completed trace
object. Scheduled, sweep-profile, ad-hoc, and on-demand paths SHALL NOT retain a
run-wide or interval-wide collection of completed traces before encoding.

#### Scenario: Scheduled result is reported
- **WHEN** a scheduled MTR check completes a probe cycle
- **THEN** the agent SHALL spool and send a typed trace event containing all
  bounded hop, ECMP, MPLS, ASN, DNS, outcome, timing, and source context
- **AND** the gateway SHALL stamp authoritative network-scope/agent/traffic-class
  context and wait for PubAck from the mapped MTR physical stream
- **AND** the producer SHALL release that completed trace after durable spooling
  while later due checks continue

#### Scenario: Sweep profile reports MTR
- **WHEN** MTR runs as part of a sweep profile
- **THEN** the sweep host observation SHALL carry summary status and `trace_id`
- **AND** the complete correlated trace SHALL be independently published to the
  MTR stream selected by the same immutable source traffic class
- **AND** neither event SHALL require the other to be decoded or committed in
  the same transaction

#### Scenario: MTR result is too large
- **WHEN** a collected trace would exceed configured field or 512 KiB frame
  bounds
- **THEN** collection SHALL enforce bounded hops, variants, labels, strings, and
  metadata or quarantine the invalid trace
- **AND** the system SHALL NOT embed it in a whole-sweep payload or retry an
  impossible message indefinitely

#### Scenario: Legacy trace is emitted during migration
- **GIVEN** a minimum dual-path-version agent has not been explicitly enabled
  for `edge-results:v1`
- **WHEN** it reports an MTR result during the compatibility window
- **THEN** it SHALL emit one independently acknowledged, byte-bounded,
  stable-ID/checksum patched legacy frame with signed network-scope/range/class
  authority
- **AND** the gateway SHALL wrap the explicitly marked format in the complete
  broker envelope and wait for PubAck from the mapped class-specific MTR stream
- **AND** EventWriter SHALL be its only database writer
- **AND** SHALL NOT infer its format by sniffing payload bytes

#### Scenario: Correlated trace is delayed or missing
- **GIVEN** a sweep or ad-hoc summary references a stable trace ID
- **WHEN** its full trace has not committed
- **THEN** the system SHALL expose that trace as pending until its reconciliation
  deadline
- **AND** later expose projected, failed, missing, or quarantined state rather
  than treating an absent trace as an empty successful path

#### Scenario: Trace ID is reused for another expected binding
- **GIVEN** a summary and trace arrive in either order
- **WHEN** the network-scope trace ID already binds a different authenticated
  agent, traffic class, source/authorization context, execution/check/command,
  or canonical target
- **THEN** the new correlation SHALL become integrity-failed/quarantined
- **AND** it SHALL NOT become projected or satisfy the execution terminal trace
  binding digest merely because the trace ID exists

### Requirement: TimescaleDB Storage
The MTR event-writer consumer SHALL persist canonical trace events into
TimescaleDB hypertables (`mtr_traces` for trace metadata and `mtr_hops` for
bounded hop/path-variant observations) using stable keys and one bounded,
idempotent transaction per source event or bounded compatible source-event group.
Every event in a group SHALL retain independent ledger/slot semantics and an
explicit post-commit JetStream ACK. ASN values SHALL be represented without
signed overflow, and absent measurements SHALL remain distinguishable from zero.
V1 `trace_id` SHALL be an RFC 9562 UUIDv7 allocated and durably recorded before
probing. `trace_identity_time` SHALL be derived only from that UUIDv7 timestamp,
validated against the signed collection interval plus attested-clock tolerance,
and used as the Timescale partition key. The trace row SHALL uniquely bind
`(trace_identity_time, network_scope_id, trace_id)` to authenticated agent,
traffic class, source/context, execution/check/command, canonical target,
observation time, content digest, and event. Hop rows SHALL reference that
physical key. A bounded partitioned summary-first expectation MAY exist only
until trace or terminal reconciliation resolves it; the system SHALL NOT retain
a permanent non-hypertable identity row per completed trace. UUID-backed IDs
SHALL use one canonical form;
nanosecond wire time SHALL follow the shared deterministic PostgreSQL-microsecond
conversion while retaining original nanoseconds where required.

#### Scenario: Trace event is ingested
- **WHEN** a canonical MTR trace event is consumed
- **THEN** one trace row SHALL be inserted or replay-safely matched by stable
  trace identity
- **AND** its hop/path-variant rows SHALL preserve full MPLS labels, ASN,
  hostname, counts, loss, RTT, jitter, and reachability semantics
- **AND** JetStream SHALL be acknowledged only after the transaction commits

#### Scenario: Trace event is redelivered
- **WHEN** the same event ID and checksum are delivered repeatedly
- **THEN** the ingest ledger and domain uniqueness constraints SHALL prevent
  duplicate trace and hop rows
- **AND** the consumer SHALL treat the already committed event as success

#### Scenario: Trace identity is reused for different content
- **WHEN** the same network-scope-scoped trace ID carries a different observation
  time, traffic class, authorization binding, or trace/hop content
- **THEN** the consumer SHALL classify it as an integrity conflict
- **AND** SHALL NOT create a second historical trace under that identity

#### Scenario: Same trace ID races across time chunks
- **WHEN** concurrent events claim one network-scope/trace ID with different
  observation times or claimed partition placement
- **THEN** both SHALL derive the same `trace_identity_time` from the UUIDv7 and
  contend on the same trace-row unique key
- **AND** placement outside the signed collection interval SHALL be rejected
- **AND** only the first authenticated trace/hop binding SHALL remain canonical

#### Scenario: Historical query by target
- **WHEN** an authorized caller queries retained MTR history for one network
  scope, target, and time range
- **THEN** trace results SHALL be returned in observation-time order
- **AND** complete retained hop data SHALL be available for each trace
- **AND** every trace/hop/identity/correlation join SHALL include the authorized
  `network_scope_id`

#### Scenario: Another network scope has the same trace or target identifier
- **GIVEN** two sites reuse an RFC1918 target or trace identifier
- **WHEN** a caller queries one network scope by trace ID, execution, target, or
  time range
- **THEN** storage policy and query predicates SHALL exclude every other network
  scope's trace, hop, correlation, rollup, and repair state
- **AND** an unscoped trace-ID lookup SHALL be rejected
