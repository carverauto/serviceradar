# observability-signals Delta

## ADDED Requirements

### Requirement: Agent observations are durably published before acknowledgement
The agent-gateway SHALL be the defined JetStream ingress publisher for
agent-originated sweep observations, execution events, and MTR traces. It SHALL
use a JetStream publish request and validate PubAck for the expected
authoritative installation-local, traffic-class-specific stream before returning
an accepted disposition for the corresponding edge spool sequence. Bulk and
interactive observations SHALL use disjoint physical streams and durable
consumers. Patched bounded legacy JSON SHALL use the same durability boundary
during migration; unpatched agents SHALL receive no new sweep or MTR work.

#### Scenario: Core NATS handoff succeeds without PubAck
- **GIVEN** a client connection accepts a Core NATS publish but no valid
  JetStream PubAck is received
- **WHEN** the gateway evaluates the result frame
- **THEN** the frame SHALL remain unacknowledged to the agent
- **AND** it SHALL remain in the crash-safe agent spool for retry

#### Scenario: Stable event is retried
- **WHEN** the gateway republishes a frame after an ambiguous prior attempt
- **THEN** it SHALL derive the same broker deduplication ID from trusted
  network-scope/agent/lane/spool ID/sequence coordinates plus the complete
  semantic-envelope digest
- **AND** the database ingest ledger SHALL remain the correctness backstop after
  the broker duplicate window expires

#### Scenario: Event ID is reused for changed bytes
- **WHEN** one semantic event ID is presented with a different payload checksum
- **THEN** its broker deduplication ID SHALL differ from the original
- **AND** the database ledger SHALL receive and reject the semantic conflict
  rather than JetStream suppressing it as an identical retry

### Requirement: Sweep and MTR use canonical domain events
Each host observation and MTR trace SHALL have one canonical typed protobuf
representation on JetStream. Producers SHALL NOT also expand the same host,
port, or hop data into generic per-field metrics. Required low-cardinality
metrics and state projections SHALL be derived downstream with stable source
correlation.

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

### Requirement: Real-time consumers subscribe before database persistence
Anomaly, causal, alerting, and other real-time consumers SHALL subscribe to the
canonical JetStream domain subjects for sweep or MTR observations rather
than query newly inserted rows back from CNPG as their event source.

#### Scenario: Trace health drives a real-time consumer
- **WHEN** a canonical MTR trace event is accepted by JetStream
- **THEN** an authorized real-time consumer MAY process the same event in
  parallel with persistence
- **AND** database query-back SHALL NOT be required to expose the observation

### Requirement: Result data-plane health is observable by bytes and age
The system SHALL expose agent spool bytes/age, gRPC in-flight bytes, PubAck
latency/errors, stream bytes/oldest age, partition lag, ack-pending,
redeliveries, consumer drain rate, DLQ counts, database write latency/WAL, and
messages/second, transactions/second, rows/transaction, commit fsyncs, WAL per
observation, execution reconciliation gaps with bounded installation-safe labels including
network scope/site, traffic class, component, and partition rather than a tenant
axis. It SHALL also expose spool reservation/I/O/corruption failures, supported
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
- **WHEN** a sweep or MTR result is quarantined, moved to a poison DLQ, or
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
