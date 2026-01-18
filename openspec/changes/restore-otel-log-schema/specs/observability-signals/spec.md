## MODIFIED Requirements
### Requirement: Raw logs ingestion
The system SHALL ingest syslog, SNMP traps, GELF logs, and OTEL logs as OTEL log records with source metadata and tenant scoping. OTEL fields (timestamp, severity, body, resource, scope, attributes, and trace/span identifiers when present) SHALL be preserved in storage and query results.

#### Scenario: SNMP trap stored as OTEL log
- **WHEN** an SNMP trap is received
- **THEN** the system SHALL persist the log as an OTEL log record
- **AND** it SHALL include source metadata and a normalized severity/body

#### Scenario: OTEL log attributes preserved
- **WHEN** an OTEL log record is ingested
- **THEN** the system SHALL retain resource attributes, scope attributes, and log attributes
- **AND** trace/span identifiers SHALL be queryable when present

## ADDED Requirements
### Requirement: OTEL log schema visibility in the UI
The Logs UI SHALL surface OTEL log fields in the detail view, including resource attributes, scope information, attributes, and trace/span identifiers when present.

#### Scenario: Log detail shows OTEL metadata
- **GIVEN** a user opens a log detail view
- **WHEN** the log record includes OTEL resource/scope/attributes
- **THEN** the UI SHALL display those OTEL fields alongside time, severity, service, and body
