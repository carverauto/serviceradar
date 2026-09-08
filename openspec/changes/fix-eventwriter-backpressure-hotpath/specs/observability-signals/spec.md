## MODIFIED Requirements
### Requirement: Signal taxonomy
The system SHALL classify observability data into logs (raw), events (derived OCSF), and alerts (stateful escalation) with consistent tenant scoping.

JetStream-backed metric, log, flow, event, and telemetry consumers SHALL apply bounded in-process backpressure so slow CNPG writes or enrichment lookups cannot cause unbounded payload retention in core-elx.

The EventWriter metrics consumer SHALL use pull-based JetStream delivery coupled to downstream demand so core-elx requests metric protobuf batches only when it has local capacity to process them.

The EventWriter metrics pipeline SHALL expose enough stream lag and processing-rate telemetry to determine whether steady-state processing capacity exceeds producer rate before JetStream retention limits are reached.

The metrics ingestion architecture SHALL document its expected capacity model, including producer count, metric sample frequency, protobuf message size, row expansion, durable consumer fanout, database write throughput, and anomaly/capacity processing cost.

For the scope of this change (the backpressure fix), the metrics anomaly and capacity architecture SHALL remain distributed through BEAM/ERTS, with Rust/DeepCausality NIFs used for measured CPU hot paths. The longer-term execution location of anomaly and capacity — including moving per-series anomaly to the edge and tiering raw storage — SHALL be decided by the `move-anomaly-detection-to-edge` and `add-delta-metrics-lakehouse` changes, and is not foreclosed here.

The metrics ingestion development workflow SHALL support local replay and benchmark runs against representative metric payloads without requiring a full demo namespace rollout for every code change.

#### Scenario: Raw syslog remains a log
- **WHEN** a syslog message is ingested
- **THEN** it SHALL be stored as a log record
- **AND** it SHALL NOT be stored as an event unless promoted by a rule

#### Scenario: Internal health state stored as an event
- **WHEN** an internal health transition is emitted
- **THEN** it SHALL be stored as an OCSF event

#### Scenario: Metric ingest slows behind JetStream delivery
- **GIVEN** the EventWriter metrics consumer is receiving large metric protobuf batches
- **AND** CNPG inserts or enrichment lookups take longer than normal
- **WHEN** Broadway has no demand or the configured in-flight capacity is full
- **THEN** the EventWriter metrics consumer SHALL stop pulling additional metric messages from JetStream
- **AND** JetStream SHALL retain undelivered messages in the stream instead of pushing them into the core-elx process
- **AND** core-elx SHALL expose observable queue pressure or in-flight signals
- **AND** it SHALL NOT retain thousands of unacked metric messages in one BEAM process

#### Scenario: Pulled metric message exceeds local capacity
- **GIVEN** the EventWriter metrics consumer has already pulled metric messages from JetStream
- **AND** downstream processing becomes slower than expected
- **WHEN** delivered metric messages exceed the configured in-process queue capacity
- **THEN** core-elx SHALL bound retained messages and binaries
- **AND** it SHALL expose observable queue pressure or overflow signals

#### Scenario: Producer rate exceeds processing rate
- **GIVEN** metric producers continue publishing at a stable rate
- **AND** EventWriter processing throughput falls below that producer rate
- **WHEN** stream lag grows toward the configured metrics stream retention window or byte limit
- **THEN** the system SHALL expose a retention-risk signal
- **AND** operators SHALL be able to distinguish temporary catch-up backlog from a sustained capacity deficit

#### Scenario: Metrics architecture is evaluated for high scale
- **GIVEN** a target deployment size of 50k metric-producing agents
- **WHEN** the metrics pipeline architecture is evaluated
- **THEN** the design SHALL estimate the steady-state message, byte, row, and durable-consumer fanout rates
- **AND** it SHALL identify how BEAM/ERTS replicas own, process, and fail over metric persistence and metric-derived anomaly/capacity work
- **AND** any standalone Rust or Go comparison SHALL be treated as benchmark evidence unless a separate distributed-state proposal is approved
- **AND** it SHALL include benchmark evidence for the selected implementation path

#### Scenario: Local metrics benchmark loop
- **GIVEN** a developer is iterating on metrics ingestion performance
- **WHEN** they run local benchmarks or a local prototype ingester
- **THEN** the workflow SHALL be able to connect to demo JetStream through a local port-forward or equivalent controlled endpoint
- **AND** it SHALL use a separate local durable consumer or captured fixtures so the live EventWriter durable is not modified accidentally
- **AND** database write tests SHALL target disposable local storage, a benchmark schema, or an explicit test window

### Requirement: Raw logs ingestion
The system SHALL ingest syslog, SNMP traps, GELF logs, and OTEL logs as OTEL log records with source metadata and tenant scoping. OTEL fields (timestamp, severity, body, resource, scope, attributes, and trace/span identifiers when present) SHALL be preserved in storage and query results.

EventWriter stream consumers SHALL support per-stream JetStream pull batch size, `ack_wait`, and `max_ack_pending` limits so high-payload streams can use smaller in-flight windows than low-payload streams.

#### Scenario: SNMP trap stored as OTEL log
- **WHEN** an SNMP trap is received
- **THEN** the system SHALL persist the log as an OTEL log record
- **AND** it SHALL include source metadata and a normalized severity/body

#### Scenario: OTEL log attributes preserved
- **WHEN** an OTEL log record is ingested
- **THEN** the system SHALL retain resource attributes, scope attributes, and log attributes
- **AND** trace/span identifiers SHALL be queryable when present

#### Scenario: Metrics stream uses bounded pull delivery
- **GIVEN** the EventWriter config defines lower limits for the `metrics.>` stream than for smaller event streams
- **WHEN** core-elx creates or updates the durable metrics consumer
- **THEN** the JetStream consumer configuration SHALL omit push `deliver_subject`
- **AND** the EventWriter producer SHALL use the metrics stream pull batch size when requesting messages
- **AND** the JetStream consumer configuration SHALL apply the metrics stream `ack_wait`
- **AND** it SHALL apply the metrics stream `max_ack_pending`
