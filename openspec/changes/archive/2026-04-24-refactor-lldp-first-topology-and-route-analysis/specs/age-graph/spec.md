## ADDED Requirements
### Requirement: Deterministic Topology Projection by Evidence Class
The graph projection layer SHALL treat evidence classes deterministically and SHALL project canonical infrastructure adjacency from `direct` evidence by default.

#### Scenario: Direct evidence projected to backbone
- **GIVEN** `direct` topology evidence between two infrastructure devices
- **WHEN** graph projection runs
- **THEN** a canonical infrastructure connectivity edge SHALL be projected
- **AND** repeated projection with unchanged evidence SHALL be idempotent

#### Scenario: Inferred evidence handled separately
- **GIVEN** `inferred` evidence between devices
- **WHEN** graph projection runs
- **THEN** inferred relationships SHALL be stored as a separate edge class
- **AND** SHALL NOT overwrite or replace existing direct backbone adjacency

### Requirement: Edge Lifecycle Stability
The graph projection layer SHALL avoid churn from partial observations by using freshness windows and edge-class-aware pruning.

#### Scenario: Partial run does not erase stable backbone
- **GIVEN** a temporary partial mapper run with missing neighbors
- **WHEN** projection executes pruning
- **THEN** existing fresh direct backbone edges SHALL remain until stale by configured TTL
- **AND** edge deletion SHALL be traceable to freshness expiry or explicit contradictory evidence
