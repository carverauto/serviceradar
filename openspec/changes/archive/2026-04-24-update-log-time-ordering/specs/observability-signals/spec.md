## ADDED Requirements
### Requirement: Logs time filtering uses observed timestamps when available
The system SHALL evaluate log time filters and ordering against an effective timestamp that prefers `observed_timestamp` when present and falls back to the event `timestamp`.

#### Scenario: Syslog without timezone appears in recent results
- **GIVEN** a syslog log record with an event `timestamp` that lacks timezone context and an `observed_timestamp` set at ingest
- **WHEN** a user queries `in:logs time:last_24h sort:timestamp:desc`
- **THEN** the log SHALL be included based on the observed timestamp
- **AND** the stored event timestamp SHALL remain unchanged in the result payload
