## ADDED Requirements
### Requirement: Worker ops surface shows current assignments
The authenticated camera analysis worker management surface SHALL show current assignment visibility for each registered worker.

#### Scenario: Worker has active branches
- **WHEN** an operator views a worker with active relay-scoped analysis branches
- **THEN** the surface SHALL show the worker's active assignment count
- **AND** it SHALL display bounded current assignment details

#### Scenario: Worker is idle
- **WHEN** an operator views a worker with no active assignments
- **THEN** the surface SHALL indicate that the worker is currently idle

### Requirement: Worker management API returns assignment visibility
The authenticated worker management API SHALL expose current assignment visibility for registered camera analysis workers.

#### Scenario: API returns assignment counts
- **WHEN** a client reads one or more registered camera analysis workers
- **THEN** each worker response SHALL include the active assignment count
- **AND** it SHALL include bounded current assignment details when any are active
