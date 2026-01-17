# observability-signals Specification (delta)

## ADDED Requirements
### Requirement: Signal taxonomy
The system SHALL classify observability data into logs (raw), events (derived OCSF), and alerts (stateful escalation) with consistent tenant scoping.

#### Scenario: Raw syslog remains a log
- **WHEN** a syslog message is ingested
- **THEN** it SHALL be stored as a log record
- **AND** it SHALL NOT be stored as an event unless promoted by a rule

#### Scenario: Internal health state stored as an event
- **WHEN** an internal health transition is emitted
- **THEN** it SHALL be stored as an OCSF event

### Requirement: Raw logs ingestion
The system SHALL ingest syslog, SNMP traps, GELF logs, and OTEL logs as raw log records with source metadata and tenant scoping.

#### Scenario: SNMP trap stored as raw log
- **WHEN** an SNMP trap is received
- **THEN** the system SHALL persist the raw payload as a log record
- **AND** it SHALL include source metadata sufficient for promotion

### Requirement: Log-to-event promotion
The system SHALL support per-tenant rules that promote log records into OCSF events and retain provenance links.

#### Scenario: Promotion creates linked event
- **GIVEN** a promotion rule that matches a log record
- **WHEN** the log is ingested
- **THEN** the system SHALL create an OCSF event
- **AND** the event SHALL reference the source log record and rule

### Requirement: Event-to-alert generation
The system SHALL allow alerts to be generated from events and SHALL link alerts to their triggering events.

#### Scenario: Critical event triggers alert
- **GIVEN** an event classified as critical by alert rules
- **WHEN** the event is created
- **THEN** an alert SHALL be created or updated
- **AND** the alert SHALL reference the triggering event

### Requirement: Observability panes in the UI
The web UI SHALL provide separate panes for logs, events, and alerts with navigation between related records.

#### Scenario: Event view links to source log and alert
- **GIVEN** a user viewing an event
- **WHEN** the event has related log or alert records
- **THEN** the UI SHALL provide navigation to those records
