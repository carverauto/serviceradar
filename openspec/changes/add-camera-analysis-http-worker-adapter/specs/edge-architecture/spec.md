## ADDED Requirements
### Requirement: External analysis workers remain downstream of the platform
The system SHALL keep HTTP analysis workers downstream of the platform-local relay branch and SHALL NOT require them to connect directly to edge agents or customer cameras.

#### Scenario: Worker processes relay-derived media input
- **GIVEN** an active relay session with an attached analysis branch
- **WHEN** the platform dispatches bounded analysis input to an external HTTP worker
- **THEN** the worker input SHALL originate from the platform-local relay branch
- **AND** the worker SHALL NOT open a direct session to the edge agent or customer camera
