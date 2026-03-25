## ADDED Requirements
### Requirement: Operators can inspect camera analysis workers in web-ng
The system SHALL provide an operator-facing `web-ng` surface to inspect registered camera analysis workers.

#### Scenario: Operator views worker status
- **GIVEN** registered camera analysis workers exist
- **WHEN** an authorized operator opens the worker management surface
- **THEN** the UI SHALL show worker identity, capabilities, enabled state, and current health state
- **AND** SHALL show recent failure or failover-relevant metadata when present
