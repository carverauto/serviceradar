## MODIFIED Requirements
### Requirement: OCSF events are the canonical event log
The system SHALL use `ocsf_events` as the canonical event log table and SHALL retire legacy `monitoring_events` storage.

#### Scenario: Legacy monitoring_events are removed
- **GIVEN** the migration to consolidate events runs
- **WHEN** tenant schema migrations are applied
- **THEN** the `monitoring_events` table SHALL no longer exist

#### Scenario: Canonical events table exists in platform schema
- **WHEN** tenant schema migrations are applied
- **THEN** the `ocsf_events` hypertable SHALL exist in the `platform` schema
- **AND** it SHALL include indexes on event time and severity for UI queries
