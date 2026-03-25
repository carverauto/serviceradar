## ADDED Requirements
### Requirement: Camera analysis worker selection is health-aware
The system SHALL maintain platform-owned health state for registered camera analysis workers and SHALL use that state during relay-scoped analysis worker selection.

#### Scenario: Capability selection skips unhealthy workers
- **GIVEN** multiple registered camera analysis workers with the requested capability
- **AND** one or more matching workers are marked unhealthy
- **WHEN** a relay-scoped analysis branch requests that capability
- **THEN** the platform SHALL select a healthy matching worker
- **AND** SHALL NOT select a worker marked unhealthy when a healthy match exists

#### Scenario: Explicit worker id targeting fails on an unhealthy worker
- **GIVEN** a registered camera analysis worker targeted by explicit id
- **AND** that worker is marked unhealthy
- **WHEN** a relay-scoped analysis branch requests that worker
- **THEN** the platform SHALL fail selection explicitly
- **AND** SHALL NOT silently reroute the branch to a different worker

### Requirement: Capability-targeted branches can fail over in a bounded way
The system SHALL support bounded worker failover for relay-scoped analysis branches that were targeted by capability rather than explicit worker id.

#### Scenario: Capability-targeted branch fails over after worker unavailability
- **GIVEN** a relay-scoped analysis branch selected by capability
- **AND** the selected worker becomes unavailable during dispatch
- **WHEN** the platform detects that unavailability
- **THEN** the platform SHALL attempt bounded reselection to another healthy matching worker
- **AND** SHALL stop after the configured bounded failover limit
