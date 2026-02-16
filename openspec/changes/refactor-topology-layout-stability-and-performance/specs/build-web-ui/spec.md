## ADDED Requirements
### Requirement: Deterministic Topology Coordinate Stability
The topology UI pipeline SHALL preserve node coordinates across updates that do not change topology revision.

#### Scenario: Overlay-only update keeps coordinates stable
- **GIVEN** topology revision is unchanged
- **WHEN** a new overlay/classification update is applied
- **THEN** node coordinates SHALL remain stable
- **AND** only visual state layers SHALL change

### Requirement: Bounded Layout Computation Budget
Topology layout recomputation SHALL run within bounded compute budgets and SHALL avoid unnecessary full-layout work for non-structural updates.

#### Scenario: Non-structural update avoids full recompute
- **GIVEN** an update changes only non-structural state
- **WHEN** the topology pipeline processes the update
- **THEN** the system SHALL skip full layout recomputation
- **AND** remain within configured latency budgets
