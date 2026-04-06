## MODIFIED Requirements
### Requirement: Raw logs ingestion
The system SHALL ingest syslog, SNMP traps, GELF logs, and OTEL logs as OTEL log records with source metadata and tenant scoping. OTEL fields (timestamp, severity, body, resource, scope, attributes, and trace/span identifiers when present) SHALL be preserved in storage and query results.

#### Scenario: SNMP trap stored as OTEL log
- **WHEN** an SNMP trap is received
- **THEN** the system SHALL persist the log as an OTEL log record
- **AND** it SHALL include source metadata and a normalized severity/body

#### Scenario: SNMP trap without a top-level body derives body from varbinds
- **GIVEN** an SNMP trap payload that does not include a top-level `body`
- **WHEN** the built-in SNMP normalization rule processes the trap
- **THEN** the persisted OTEL log record SHALL derive `body` from the first meaningful trap varbind text
- **AND** it SHALL NOT persist the NATS subject placeholder `logs.snmp.processed` as the body

#### Scenario: OTEL log attributes preserved
- **WHEN** an OTEL log record is ingested
- **THEN** the system SHALL retain resource attributes, scope attributes, and log attributes
- **AND** trace/span identifiers SHALL be queryable when present
