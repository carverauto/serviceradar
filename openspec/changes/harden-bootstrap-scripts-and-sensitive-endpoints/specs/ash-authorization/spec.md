## MODIFIED Requirements
### Requirement: Actor-Based Authorization
The system SHALL enforce authorization based on the actor (user, API token, or system) performing actions, and sensitive controller endpoints SHALL perform explicit authorization checks rather than relying only on router placement.

#### Scenario: Topology snapshot requires explicit authorization
- **GIVEN** an authenticated request reaches the topology snapshot controller
- **WHEN** the current actor lacks the required topology permission
- **THEN** the controller SHALL deny access
- **AND** the snapshot payload SHALL NOT be served

#### Scenario: Spatial samples require explicit authorization
- **GIVEN** an authenticated request reaches the spatial samples controller
- **WHEN** the current actor lacks the required permission for spatial survey data
- **THEN** the controller SHALL deny access
- **AND** the spatial sample payload SHALL NOT be served
