## ADDED Requirements
### Requirement: Camera analysis workers expose current assignment visibility
The platform SHALL derive current relay-scoped assignment visibility for registered camera analysis workers from the active analysis dispatch runtime.

#### Scenario: Worker has active assignments
- **GIVEN** one or more relay-scoped analysis branches are currently assigned to a registered worker
- **WHEN** the platform reads current worker assignment state
- **THEN** it SHALL report that worker's active assignment count
- **AND** it SHALL include bounded current assignment details for that worker

#### Scenario: Worker has no active assignments
- **GIVEN** no relay-scoped analysis branches are currently assigned to a registered worker
- **WHEN** the platform reads current worker assignment state
- **THEN** it SHALL report zero active assignments for that worker

### Requirement: Worker assignment visibility follows dispatch lifecycle
The platform SHALL update worker assignment visibility when analysis dispatch branches open, fail over, or close.

#### Scenario: Branch failover changes worker assignment
- **WHEN** an active analysis branch fails over from one registered worker to another
- **THEN** the previous worker's active assignment count SHALL decrease
- **AND** the replacement worker's active assignment count SHALL increase
