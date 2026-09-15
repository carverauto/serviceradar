## MODIFIED Requirements

### Requirement: Metric Ingestion via JetStream
All metric and telemetry sources SHALL publish to a NATS JetStream subject and be persisted by the event-writer consumer pipeline into the configured analytics store (Timescale hypertables or pg_duckdb/Parquet). Collectors and agents SHALL NOT write metrics directly to CNPG or to the Parquet backend, and core SHALL NOT ingest a metric path that bypassed JetStream. This keeps every metric stream subscribable by real-time consumers (anomaly detection, the causal engine) rather than being visible only after it lands in the store.

#### Scenario: New metric source added
- **WHEN** a new metric or telemetry source is introduced
- **THEN** it SHALL publish to a JetStream subject consumed by the event-writer pipeline
- **AND** it SHALL NOT write directly to CNPG or to Parquet storage

#### Scenario: Sysmon metrics migrated off the direct-to-DB path
- **WHEN** sysmon cpu/memory/disk/process metrics are collected by an agent
- **THEN** they SHALL be published to a JetStream subject and persisted by the event-writer consumer
- **AND** the legacy gRPC `StreamStatus` path that wrote sysmon metrics directly to the database SHALL be retired once the JetStream path reaches parity

### Requirement: Defined Ingress Publisher and Single Database Writer
Each telemetry type SHALL have exactly one defined ingress publisher to NATS JetStream, and all telemetry SHALL be persisted into the configured analytics store by a single writer. The system SHALL NOT run two writers persisting the same records to the same store table except during an explicit, named dual-write cutover flag, and SHALL NOT persist any telemetry path that bypassed JetStream.

#### Scenario: One publisher per telemetry type
- **WHEN** a telemetry type (e.g. OTLP, flows, SNMP traps, host metrics) is ingested
- **THEN** exactly one component SHALL be responsible for publishing it to JetStream
- **AND** other components SHALL forward into that publisher rather than re-publishing the same data

#### Scenario: One writer per table
- **WHEN** a telemetry record is persisted to the analytics store
- **THEN** exactly one consumer SHALL be responsible for writing that record's table
- **AND** there SHALL NOT be a second consumer writing the same rows that relies on conflict-dedup to avoid duplicates, except while a named cutover flag is on

#### Scenario: Legacy persister retired
- **WHEN** the consolidated single-writer pipeline reaches parity for the tables previously written by the standalone persister
- **THEN** the standalone persister SHALL be retired so a single writer owns persistence
