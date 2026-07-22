# observability-signals Delta

## MODIFIED Requirements

### Requirement: Required Local OTLP Terminator on Every Agent
Every agent SHALL include a local OTLP terminator (the `otel-collector` add-on)
as a required, auto-installed component so OTLP emitted at the edge has a local
endpoint. The terminator SHALL retain uncertain telemetry until the agent's
generic native record relay returns a cumulative common-spool durability ACK.
The agent SHALL carry canonical OTLP/observability records through the
authenticated gateway record plane, and the gateway SHALL be the sole NATS
publisher for agent-originated OTLP in this contract. A site-local NATS leaf MAY
be part of the gateway's configured route only when the observed PubAck is from
the declared durability authority; the terminator SHALL NOT receive broker
credentials or bypass the common agent spool/registry/envelope semantics.

#### Scenario: Agent installed without explicit add-on assignment
- **WHEN** an agent is installed
- **THEN** the local OTLP terminator add-on SHALL be installed by default without
  an operator assigning it
- **AND** its durable output grant and native relay identity SHALL be compiled by
  the platform

#### Scenario: Edge site without a NATS leaf
- **WHEN** OTLP is emitted at an edge site that has no local NATS access
- **THEN** the terminator SHALL relay it through the agent to the agent-gateway,
  which publishes it to NATS
- **AND** the terminator SHALL retain it until common-spool durability ACK, after
  which the agent SHALL retain it until the corresponding edge PubAck disposition

#### Scenario: Edge site with a NATS leaf
- **WHEN** a NATS leaf is deployed at the edge site
- **THEN** the terminator SHALL still use the assignment-authenticated native
  record relay and common agent spool
- **AND** any gateway publication through the leaf SHALL wait for the configured
  authoritative durability PubAck before edge acknowledgement

## ADDED Requirements

### Requirement: Agent durable records are published before edge acknowledgement
The agent-gateway SHALL be the defined JetStream ingress publisher for
agent-originated persistent observations, metrics, inventory, findings,
execution events, traces, and approved extension records. It SHALL
use a JetStream publish request and validate PubAck for the expected
authoritative installation-local, traffic-class-specific stream before returning
an accepted disposition for the corresponding edge spool sequence. Bulk and
interactive records SHALL use disjoint physical streams and durable consumers.
Agents below the required edge-record protocol version SHALL receive no new
affected work; the installation SHALL NOT add a patched legacy JSON sender.

#### Scenario: Core NATS handoff succeeds without PubAck
- **GIVEN** a client connection accepts a Core NATS publish but no valid
  JetStream PubAck is received
- **WHEN** the gateway evaluates the result frame
- **THEN** the frame SHALL remain unacknowledged to the agent
- **AND** it SHALL remain in the crash-safe agent spool for retry

#### Scenario: Stable event is retried
- **WHEN** the gateway republishes a frame after an ambiguous prior attempt
- **THEN** it SHALL derive the same broker deduplication ID from trusted
  network-scope/agent/spool ID/sequence coordinates, the frame's exact-record
  `record_sha256`, plus the complete semantic-envelope digest
- **AND** the database ingest ledger SHALL remain the correctness backstop after
  the broker duplicate window expires

#### Scenario: Event ID is reused for changed bytes
- **WHEN** one semantic event ID is presented with a different `payload_sha256`
  (hence a different `semantic_envelope_sha256`)
- **THEN** its broker deduplication ID SHALL differ from the original
- **AND** the database ledger SHALL receive and reject the semantic conflict on
  the differing `semantic_envelope_sha256`
  rather than JetStream suppressing it as an identical retry

### Requirement: Durable producer output has one canonical domain record
Every durable output contract SHALL define one canonical typed or approved
extension representation on JetStream with deterministic domain identity,
revision/merge semantics, and authoritative-versus-derived status. Producers
SHALL NOT emit the same fact simultaneously as typed output, extension output,
generic per-field metrics, OCSF, plugin-result JSON, or a lossy add-on copy.
Required low-cardinality metrics and state projections SHALL be derived
downstream with stable source correlation.

#### Scenario: Sweep host observation is published
- **WHEN** an agent publishes an ICMP/TCP host observation
- **THEN** the canonical sweep event SHALL be available to persistence and
  real-time consumers
- **AND** the agent SHALL NOT publish a duplicate metric point for every host
  and tested port after migration parity

#### Scenario: Full MTR trace is published
- **GIVEN** later traces in a long-lived execution are still running
- **WHEN** an agent completes and publishes one enriched MTR trace
- **THEN** its structured hop, ECMP, MPLS, ASN, DNS, timing, outcome, and
  correlation fields SHALL be present in the canonical trace event
- **AND** the completed trace SHALL enter a bounded frame and durable spool
  without waiting for the run or interval to finish
- **AND** the source SHALL NOT retain a run-wide or interval-wide completed-trace
  slice
- **AND** it SHALL NOT be flattened into generic metric attributes as the
  authoritative trace

#### Scenario: Existing metric consumer needs a projection
- **GIVEN** a supported consumer cannot yet read the domain event
- **WHEN** a compatibility metric projection is required
- **THEN** exactly one downstream normalizer MAY produce a bounded,
  low-cardinality, idempotent projection correlated to the source event
- **AND** it SHALL NOT become a second database writer for the same domain rows

#### Scenario: Wasm or native producer emits persistent telemetry
- **WHEN** a plugin or add-on submits an approved persistent metric, finding, or
  event contract
- **THEN** the authoritative record SHALL become available to persistence and
  authorized real-time consumers through JetStream
- **AND** the producer SHALL NOT duplicate it through `plugin_result`, base64/
  JSON telemetry, or a drain-before-send lossy queue

#### Scenario: Runtime health is explicitly ephemeral
- **WHEN** a producer reports bounded coalescible runtime health
- **THEN** `GatewayServiceStatus` MAY carry that current status
- **AND** the status path SHALL NOT be described as persistent time-series or
  event ingestion

### Requirement: Real-time consumers subscribe before database persistence
Anomaly, causal, alerting, and other real-time consumers SHALL subscribe to the
canonical fixed JetStream edge-record subjects and decode trusted output-contract
fields from the binary `EdgeRecordV1` body for persistent observations rather
than query newly inserted rows back from CNPG as their event source. Semantic
identity and authority SHALL NOT depend on copied broker headers.

#### Scenario: Trace health drives a real-time consumer
- **WHEN** a canonical MTR trace event is accepted by JetStream
- **THEN** an authorized real-time consumer MAY process the same event in
  parallel with persistence
- **AND** database query-back SHALL NOT be required to expose the observation

#### Scenario: Plugin finding drives a real-time consumer
- **WHEN** an approved plugin finding receives authoritative JetStream PubAck
- **THEN** an authorized real-time consumer MAY process it before EventWriter
  commits CNPG projection
- **AND** no direct database query-back SHALL be required as the event source

### Requirement: Result data-plane health is observable by bytes and age
The system SHALL expose agent spool bytes/age, gRPC in-flight bytes, PubAck
latency/errors, stream bytes/oldest age, partition lag, ack-pending,
redeliveries, consumer drain rate, DLQ counts, database write latency/WAL, and
messages/second, transactions/second, rows/transaction, commit fsyncs, WAL per
observation, execution reconciliation gaps with bounded installation-safe labels including
network scope/site, traffic class, component, and partition rather than a tenant
axis. Producer pressure/rejection SHALL be aggregated by bounded producer kind
and output contract, not high-cardinality producer instance/run labels. It SHALL
also expose spool reservation/I/O/corruption failures, supported
outage/catch-up headroom, retention-boundary risk,
scanner/delivery/projection/MTR substates, recovery publication PubAck state,
consumer-commit resolution state, and journals awaiting durable
`RecoveryResolvedV1`. It SHALL also expose correctness-metadata rows/index bytes,
oldest live retirement bucket, partition-retirement lag/rate, acceptance
watermark, exceptional hold count/bytes by state and class, and admission stops
caused by that hard budget.

#### Scenario: Retention exhaustion is approaching
- **WHEN** projected ingress and consumer drain rates would exhaust a stream or
  agent spool before the configured outage plus catch-up and safety window
- **THEN** the system SHALL alert before data admission is refused
- **AND** the alert SHALL identify the constrained layer without high-cardinality
  host labels

#### Scenario: Bulk backlog grows while interactive work remains healthy
- **WHEN** bulk stream or durable-consumer age and bytes exceed their threshold
- **THEN** bulk health metrics and alerts SHALL identify the bulk path
- **AND** interactive stream capacity, age, and drain rate SHALL be reported
  independently rather than hidden in a shared result-stream aggregate

#### Scenario: Result enters quarantine or DLQ
- **WHEN** any durable producer result is quarantined, moved to a poison DLQ, or
  redriven
- **THEN** metrics and audit records SHALL preserve its original traffic class
- **AND** redrive and backlog accounting SHALL remain on the same class path and
  SHALL NOT report bulk work as interactive

#### Scenario: Recovery publication is acknowledged but unresolved
- **GIVEN** the recovery stream has returned PubAck for a manifest
- **WHEN** no signed durable `RecoveryResolvedV1` or confirming idempotent query
  has established scheduler-repair consumer commit
- **THEN** observability SHALL report publication as complete but recovery as
  unresolved
- **AND** SHALL report the local journal as retained rather than garbage
  collected
