## ADDED Requirements
### Requirement: Analysis branches stay platform-local
The system SHALL run camera stream analysis from platform-local relay branches and SHALL NOT require browsers or external workers to connect directly to edge agents or customer cameras.

#### Scenario: External worker receives analysis input
- **GIVEN** an active camera relay session
- **WHEN** the platform forwards bounded analysis input to an external worker
- **THEN** the worker input SHALL originate from the platform relay branch
- **AND** the worker SHALL NOT open a direct session to the edge agent or customer camera
