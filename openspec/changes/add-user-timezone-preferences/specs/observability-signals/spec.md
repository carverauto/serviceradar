## ADDED Requirements

### Requirement: Observability timestamps honor the user timezone

The web UI SHALL present human-visible absolute timestamps for logs, syslog messages, SNMP traps, GELF and OTEL logs, events, alerts, metrics, and traces in the authenticated user's saved timezone. List rows, detail views, correlated records, chart labels, and chart tooltips SHALL use the shared user-timezone rendering contract while the stored and queried timestamp instants remain unchanged.

#### Scenario: Log and trap surfaces use the saved timezone

- **GIVEN** a user with timezone `America/Chicago`
- **AND** syslog, SNMP trap, GELF, and OTEL log records with canonical UTC timestamps
- **WHEN** the user views the log list or a record detail
- **THEN** each human-visible absolute timestamp SHALL render in `America/Chicago`
- **AND** the original UTC instant SHALL remain available as machine-readable and accessible metadata

#### Scenario: Metric and trace correlation preserves canonical pivots

- **GIVEN** a metric or trace timestamp displayed in the user's timezone
- **WHEN** the user pivots to correlated logs, traces, metrics, or events
- **THEN** the generated time bounds SHALL use the original canonical UTC instant
- **AND** correlation results SHALL not depend on the localized label

#### Scenario: Source timestamp without timezone is not reinterpreted

- **GIVEN** a syslog record whose source event timestamp lacked timezone context and whose effective observed timestamp was selected at ingest
- **WHEN** the record is displayed in the user's timezone
- **THEN** localization SHALL apply to the already-selected canonical effective instant
- **AND** SHALL NOT reinterpret the original source wall-clock value or change filtering and ordering

#### Scenario: Observability API and export values remain UTC

- **GIVEN** an observability timestamp localized in the interactive UI
- **WHEN** the same record is serialized through an API, copied as its canonical value, or included in a downloadable export
- **THEN** the machine-facing timestamp SHALL remain canonical UTC ISO-8601
