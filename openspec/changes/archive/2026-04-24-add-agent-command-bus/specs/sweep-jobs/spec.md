## ADDED Requirements
### Requirement: On-demand sweeps via command bus
The system SHALL allow admins to trigger sweep group execution on demand via the command bus when an assigned agent is online.

#### Scenario: Run sweep group now
- **GIVEN** a sweep group assigned to an online agent
- **WHEN** the admin selects "Run now"
- **THEN** the system sends a sweep command over the control stream
- **AND** the UI receives command status updates

#### Scenario: Run sweep group while agent offline
- **GIVEN** a sweep group assigned to an offline agent
- **WHEN** the admin selects "Run now"
- **THEN** the system returns an immediate error
