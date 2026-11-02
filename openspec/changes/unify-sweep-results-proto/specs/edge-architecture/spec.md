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
and plugin telemetry SHALL enter through an authenticated,
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

#### Scenario: Sync results ingestion via gRPC stream
- **GIVEN** an agent emits sync results that exceed single-message limits
- **WHEN** the agent streams the results via `StreamStatus`
- **THEN** the agent-gateway MAY forward the chunked payload through the
  existing sync gRPC-to-core route only when it is already-accepted pre-cutover
  backlog, as described in "Pre-cutover legacy sync backlog drains"
- **AND** new or migrated persistent integration output SHALL NOT use that route
  and SHALL use the durable record plane

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
- **GIVEN** a Wasm plugin, native add-on, or embedded integration emits through
  the plugin telemetry contract under the agent's standing output grant
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

#### Scenario: Status and results use standard methods
- **GIVEN** an agent emits regular status updates and smaller results payloads
- **WHEN** the agent calls `PushStatus`
- **THEN** the agent-gateway MAY forward bounded non-persistent status through
  the existing gRPC/ERTS control route, as described in "Control and small
  status remain direct"
- **AND** already-accepted pre-cutover sync backlog MAY stay on the sync
  ingestor path, as described in "Pre-cutover legacy sync backlog drains"
- **AND** new or migrated persistent output, other than `sweep`, SHALL NOT
  share that status routing and SHALL use the durable record plane as described
  in "Plugin or integration publishes persistent output"
- **AND** new or migrated persistent `sweep` results SHALL use the durable
  record plane as described in "Sweep observations use layered delivery"

### Requirement: Results routing is explicit by output contract
The durable result pipeline SHALL route typed platform records and spool-loss recovery tombstones
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

#### Scenario: Results routing selects the correct handler
- **GIVEN** core receives a results payload tagged as `sync` or `sweep`
- **WHEN** the result pipeline routes persistent data
- **THEN** it SHALL NOT select a handler from the result-type tag alone
- **AND** already-accepted pre-cutover sync backlog MAY stay on the sync
  ingestor path, as described in "Pre-cutover legacy sync backlog drains"
- **AND** new or migrated persistent output SHALL route by exact output
  contract, route profile, and schema version as described in "Versioned record
  selects its route and projector"

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

## ADDED Requirements

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
