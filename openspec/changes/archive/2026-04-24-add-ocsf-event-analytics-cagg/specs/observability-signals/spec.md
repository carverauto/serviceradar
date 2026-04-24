## ADDED Requirements
### Requirement: Event severity aggregates for analytics
The system SHALL maintain hourly aggregates of OCSF event severity counts for analytics queries.

#### Scenario: Hourly aggregate available for last 24h
- **WHEN** events are ingested over the last 24 hours
- **THEN** the system SHALL expose hourly severity counts for Critical, High, Medium, and Low events
- **AND** the analytics UI SHALL be able to query those counts without scanning raw events
