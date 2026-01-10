## ADDED Requirements

### Requirement: OCSF event writes broadcast PubSub updates
The system SHALL broadcast a per-tenant PubSub event when internal OCSF events are recorded so the Events UI can refresh live.

#### Scenario: Events UI receives PubSub refresh
- **GIVEN** an internal service writes an OCSF event for a tenant
- **WHEN** the event is persisted
- **THEN** the per-tenant PubSub topic SHALL receive a refresh event
- **AND** the Events UI SHALL be able to reload the new entry

### Requirement: OCSF events are the canonical event log
The system SHALL use `ocsf_events` as the canonical event log table and SHALL retire legacy `monitoring_events` storage.

#### Scenario: Legacy monitoring_events are removed
- **GIVEN** the migration to consolidate events runs
- **WHEN** tenant schema migrations are applied
- **THEN** the `monitoring_events` table SHALL no longer exist
