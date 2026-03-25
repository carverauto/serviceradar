## ADDED Requirements
### Requirement: The platform must provide an executable reference worker for analysis contracts
The system SHALL provide an executable reference analysis worker that validates the platform-owned analysis worker contract without requiring direct access to edge agents or customer cameras.

#### Scenario: Reference worker validates the contract
- **GIVEN** an active relay session with an attached analysis branch
- **WHEN** the platform dispatches a bounded analysis input to the reference worker
- **THEN** the worker SHALL process only the normalized platform input payload
- **AND** SHALL NOT open a direct session to the edge agent or customer camera
