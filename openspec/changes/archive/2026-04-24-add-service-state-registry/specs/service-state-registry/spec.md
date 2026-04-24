## ADDED Requirements
### Requirement: Service State Registry
The system SHALL maintain a durable current-state registry for each service identity so the UI can show present-time availability.

#### Scenario: Status upsert updates state
- **GIVEN** a service status update for a service identity
- **WHEN** the status is ingested
- **THEN** the system upserts the current service state record
- **AND** the record reflects the latest availability and timestamp

### Requirement: Service Removal Updates State
The system SHALL update the service state registry when a service assignment is revoked or deleted.

#### Scenario: Plugin revoked
- **GIVEN** a plugin service assignment is revoked or deleted
- **WHEN** the revocation is processed
- **THEN** the service state registry is updated to remove or disable that service identity
- **AND** the Services UI reflects one fewer active service without waiting for new status data

### Requirement: Service State PubSub
The system SHALL broadcast service state changes so LiveView can refresh without a full page reload.

#### Scenario: State update triggers refresh
- **GIVEN** a service state update
- **WHEN** it is persisted
- **THEN** the system broadcasts a service-state update event
- **AND** the Services LiveView refreshes its summary

### Requirement: Services Dashboard Uses Current State
The Services dashboard summary SHALL compute totals from the service state registry.

#### Scenario: Present-time counts
- **GIVEN** a service state registry with N active services
- **WHEN** a user views the Services dashboard
- **THEN** the totals reflect the current registry entries
