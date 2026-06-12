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

### Requirement: Anomaly and Capacity Signal Routing
Anomaly findings and capacity-forecast findings SHALL be emitted through the existing causal-engine emission spine (causal prediction signals routed into OCSF events) so they reach the standard event-to-alert pipeline without introducing a separate inbound routing path or a separate alert engine.

#### Scenario: Anomaly finding becomes an alert
- **WHEN** the detector confirms a sustained anomaly for a series associated with a device
- **THEN** it SHALL emit an anomaly verdict that is routed into OCSF events
- **AND** the existing stateful alert engine SHALL evaluate it and raise a device-grouped alert

#### Scenario: Capacity finding becomes an alert
- **WHEN** a resource is projected to exhaust within the warning horizon
- **THEN** a capacity-forecast verdict SHALL be routed into OCSF events and evaluated by the existing alert engine
