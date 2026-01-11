# Capability: observability-signals (delta)

## ADDED Requirements
### Requirement: Integration sync lifecycle logging
The system SHALL record integration sync lifecycle updates as OTEL log records and SHALL NOT emit OCSF events by default.

#### Scenario: Sync start recorded as a log
- **GIVEN** an integration source begins a sync
- **WHEN** the sync start is recorded
- **THEN** the system SHALL write a log record to the tenant logs table
- **AND** the log SHALL include the integration source identifier and stage "started"

#### Scenario: Sync failure remains a log unless promoted
- **GIVEN** an integration sync finishes with result "failed" or "timeout"
- **WHEN** the sync finish is recorded
- **THEN** the system SHALL write a log record with the result and error details
- **AND** it SHALL NOT create an OCSF event unless a promotion rule matches
