## ADDED Requirements

### Requirement: Metric Ingestion via JetStream
All metric and telemetry sources SHALL publish to a NATS JetStream subject and be persisted into the database by the event-writer consumer pipeline. Collectors and agents SHALL NOT write metrics directly to the database, and core SHALL NOT ingest a metric path that bypassed JetStream. This keeps every metric stream subscribable by real-time consumers (anomaly detection, the causal engine) rather than being visible only after it lands in a hypertable.

#### Scenario: New metric source added
- **WHEN** a new metric or telemetry source is introduced
- **THEN** it SHALL publish to a JetStream subject consumed by the event-writer pipeline
- **AND** it SHALL NOT write directly to the database

#### Scenario: Sysmon metrics migrated off the direct-to-DB path
- **WHEN** sysmon cpu/memory/disk/process metrics are collected by an agent
- **THEN** they SHALL be published to a JetStream subject and persisted by the event-writer consumer
- **AND** the legacy gRPC `StreamStatus` path that wrote sysmon metrics directly to the database SHALL be retired once the JetStream path reaches parity

### Requirement: Defined Ingress Publisher and Single Database Writer
Each telemetry type SHALL have exactly one defined ingress publisher to NATS JetStream, and all telemetry SHALL be persisted into the database by a single writer. The system SHALL NOT run two writers persisting the same records to the same tables, and SHALL NOT persist any telemetry path that bypassed JetStream.

#### Scenario: One publisher per telemetry type
- **WHEN** a telemetry type (e.g. OTLP, flows, SNMP traps, host metrics) is ingested
- **THEN** exactly one component SHALL be responsible for publishing it to JetStream
- **AND** other components SHALL forward into that publisher rather than re-publishing the same data

#### Scenario: One writer per table
- **WHEN** a telemetry record is persisted to the database
- **THEN** exactly one consumer SHALL be responsible for writing that record's table
- **AND** there SHALL NOT be a second consumer writing the same rows that relies on conflict-dedup to avoid duplicates

#### Scenario: Legacy persister retired
- **WHEN** the consolidated single-writer pipeline reaches parity for the tables previously written by the standalone persister
- **THEN** the standalone persister SHALL be retired so a single writer owns persistence

#### Scenario: No publish-then-read-back loop for persistence
- **WHEN** a component generates or relays telemetry that must be persisted
- **THEN** it SHALL NOT publish that record to the message bus solely to consume its own message back in order to write it to the database
- **AND** normalization required before persistence SHALL run in-process rather than in a separate round-tripping component

### Requirement: Leaf-Compatible Ingress Publishing
Ingress publishers SHALL publish to a configurable NATS endpoint so they can run against a local NATS leaf node at a customer edge site or against the central hub, and the subjects they publish SHALL federate cleanly to the hub JetStream stream. Publishers SHALL NOT assume co-location with the JetStream stream or hardcode the central endpoint.

#### Scenario: Publisher runs against an edge leaf
- **WHEN** an ingress publisher is configured with a local NATS leaf endpoint
- **THEN** it SHALL publish to that endpoint
- **AND** its subjects SHALL federate to the central hub stream without reconfiguring downstream consumers

### Requirement: Required Local OTLP Terminator on Every Agent
Every agent SHALL include a local OTLP terminator (the `otel-collector` add-on) as a required, auto-installed component, so that OTLP emitted at the edge (by plugins, add-ons, local apps, or the agent itself) always has a local endpoint. The terminator SHALL durably spool accepted telemetry, and SHALL support both a gateway-relay transport (requiring no edge NATS) and a direct-to-NATS-leaf transport (when a leaf is deployed at the site).

#### Scenario: Agent installed without explicit add-on assignment
- **WHEN** an agent is installed
- **THEN** the local OTLP terminator add-on SHALL be installed by default without an operator assigning it

#### Scenario: Edge site without a NATS leaf
- **WHEN** OTLP is emitted at an edge site that has no local NATS access
- **THEN** the terminator SHALL relay it through the agent to the agent-gateway, which publishes it to NATS
- **AND** the telemetry SHALL be durably spooled until the gateway acknowledges it

#### Scenario: Edge site with a NATS leaf
- **WHEN** a NATS leaf is deployed at the edge site
- **THEN** the terminator MAY publish directly to the local leaf, which federates to the central hub

### Requirement: Total-Order Context Updates
Per-series detector context SHALL be updated in total temporal order regardless of how many producers emit updates concurrently. Each context-update event SHALL carry a time-sortable identifier with an embedded high-resolution timestamp (e.g. UUIDv8), stamped once at the ingress gateway so there is a single clock domain, and the context engine SHALL fold updates in that total order. Folding SHALL be idempotent so that replayed or duplicated updates do not corrupt context.

#### Scenario: Concurrent updates from multiple producers
- **WHEN** updates for the same series arrive from multiple producers, possibly out of arrival order
- **THEN** the context engine SHALL apply them in total temporal order by their sortable identifier
- **AND** the resulting context SHALL be deterministic and independent of arrival order

#### Scenario: Identifier stamped at ingress
- **WHEN** a telemetry sample enters the system at the ingress gateway
- **THEN** its time-sortable identifier SHALL be assigned there (first contact, one clock domain)
- **AND** the original sample timestamp SHALL be preserved as a separate field

#### Scenario: Replayed update is idempotent
- **WHEN** a context-update event is delivered more than once
- **THEN** folding it again SHALL NOT change the context beyond its first application

### Requirement: Anomaly and Capacity Signal Routing
Anomaly findings and capacity-forecast findings SHALL be emitted through the existing causal-engine emission spine (causal prediction signals routed into OCSF events) so they reach the standard event-to-alert pipeline without introducing a separate inbound routing path or a separate alert engine.

#### Scenario: Anomaly finding becomes an alert
- **WHEN** the detector confirms a sustained anomaly for a series associated with a device
- **THEN** it SHALL emit an anomaly verdict that is routed into OCSF events
- **AND** the existing stateful alert engine SHALL evaluate it and raise a device-grouped alert

#### Scenario: Capacity finding becomes an alert
- **WHEN** a resource is projected to exhaust within the warning horizon
- **THEN** a capacity-forecast verdict SHALL be routed into OCSF events and evaluated by the existing alert engine
