## MODIFIED Requirements
### Requirement: Log-to-event promotion
The system SHALL support per-tenant rules that promote log records into OCSF events, persist them in the `ocsf_events` table, and retain provenance links.

#### Scenario: Promotion creates linked event
- **GIVEN** a promotion rule that matches a log record
- **WHEN** the log is ingested
- **THEN** the system SHALL create an OCSF event in `ocsf_events`
- **AND** the event SHALL reference the source log record and rule

#### Scenario: Promotion from processed log subjects
- **GIVEN** logs are ingested via processed NATS subjects (`logs.*.processed`)
- **WHEN** a processed log matches an enabled event rule
- **THEN** the promotion pipeline SHALL create an OCSF event without duplicating log inserts
