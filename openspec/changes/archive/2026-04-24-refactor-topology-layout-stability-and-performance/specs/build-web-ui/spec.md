## ADDED Requirements
### Requirement: Deterministic Topology Coordinate Stability
The topology UI pipeline SHALL preserve node coordinates across updates that do not change topology revision.

#### Scenario: Overlay-only update keeps coordinates stable
- **GIVEN** topology revision is unchanged
- **WHEN** a new overlay/classification update is applied
- **THEN** node coordinates SHALL remain stable
- **AND** only visual state layers SHALL change

### Requirement: Infrastructure-Anchored Layered Layout
The topology UI layout pipeline SHALL use deterministic infrastructure-aware anchoring and layered placement instead of degree-only concentric-ring placement for high-fanout topologies.

#### Scenario: High-fanout topology avoids single-ring hairball
- **GIVEN** a topology where one infrastructure node has high endpoint fanout
- **WHEN** coordinates are computed
- **THEN** infrastructure/root tiers SHALL be placed in deterministic anchor layers
- **AND** endpoints SHALL be distributed in lower layers instead of a single dense ring around one root

#### Scenario: Deterministic anchor selection
- **GIVEN** identical topology structure and node role/weight inputs
- **WHEN** layout is computed multiple times
- **THEN** anchor selection SHALL be identical across runs
- **AND** resulting coordinates SHALL remain deterministic

### Requirement: Bounded Layout Computation Budget
Topology layout recomputation SHALL run within bounded compute budgets and SHALL avoid unnecessary full-layout work for non-structural updates.

#### Scenario: Non-structural update avoids full recompute
- **GIVEN** an update changes only non-structural state
- **WHEN** the topology pipeline processes the update
- **THEN** the system SHALL skip full layout recomputation
- **AND** remain within configured latency budgets

#### Scenario: Layout hot path avoids unnecessary heavy graph analytics
- **GIVEN** a standard binary-link topology snapshot
- **WHEN** layout coordinates are computed
- **THEN** coordinate placement SHALL NOT depend on per-snapshot betweenness centrality computation
- **AND** SHALL use the optimized primary geometry path defined for binary topology links

### Requirement: Typed Telemetry Fast Path for Snapshot Encoding
The topology snapshot encoding pipeline SHALL consume typed telemetry values and SHALL NOT use per-edge JSON parsing fallback in the runtime hot path.

#### Scenario: Typed edge telemetry is mandatory in runtime hot path
- **GIVEN** edge telemetry includes typed numeric `flow_pps`, `flow_bps`, and `capacity_bps` values
- **WHEN** snapshot encoding runs
- **THEN** the encoder SHALL use typed numeric fields as the source of truth
- **AND** the runtime hot path SHALL NOT parse JSON metadata to derive telemetry values
