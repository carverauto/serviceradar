## ADDED Requirements

### Requirement: Sync ingestion transitions emit OCSF events
The system SHALL record OCSF Event Log Activity entries when an integration source sync ingestion starts and finishes.

#### Scenario: Sync ingestion start and finish events
- **GIVEN** a sync ingestion run for an integration source
- **WHEN** the ingestion transitions to running and then completes
- **THEN** the tenant `ocsf_events` table SHALL include start and finish entries
- **AND** the events SHALL include the integration source ID and result
