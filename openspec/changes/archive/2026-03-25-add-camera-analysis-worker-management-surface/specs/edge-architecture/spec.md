## ADDED Requirements
### Requirement: Camera analysis workers have a supported management API
The system SHALL provide an authenticated management surface for platform-registered camera analysis workers.

#### Scenario: Operator lists registered workers
- **GIVEN** one or more registered camera analysis workers
- **WHEN** an authorized operator requests the worker list
- **THEN** the platform SHALL return the registered workers with identity, adapter, endpoint, capability, enabled, and health state

#### Scenario: Operator disables a worker
- **GIVEN** a registered camera analysis worker
- **WHEN** an authorized operator disables that worker through the management surface
- **THEN** the platform SHALL persist that state on the worker registry model
- **AND** subsequent dispatch selection SHALL treat that worker as unavailable
