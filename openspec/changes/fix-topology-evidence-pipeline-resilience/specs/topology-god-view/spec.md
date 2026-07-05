# topology-god-view — deltas

## ADDED Requirements

### Requirement: Snapshot exposes edge-class counts and backbone-empty state
The god-view snapshot payload SHALL include per-edge-class counts (backbone, attachment/endpoints, inferred, hosted) in its metadata, and the topology UI SHALL render an explicit degraded-state signal when the served snapshot contains zero backbone-class edges, instead of silently rendering disconnected islands.

#### Scenario: Backbone-empty snapshot renders a warning state
- **GIVEN** a served snapshot whose backbone-class edge count is zero
- **AND** attachment or inferred edges exist in the snapshot
- **WHEN** the topology surface renders
- **THEN** a visible warning SHALL state that backbone topology is unavailable
- **AND** the warning SHALL offer enabling the attachment/inferred layers as an explicit action
- **AND** the debug status line SHALL include per-class edge counts

#### Scenario: Healthy snapshot renders no warning
- **GIVEN** a served snapshot with a non-zero backbone-class edge count
- **WHEN** the topology surface renders
- **THEN** no degraded-state warning SHALL be shown
