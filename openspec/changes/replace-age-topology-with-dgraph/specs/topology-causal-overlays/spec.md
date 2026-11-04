## MODIFIED Requirements

### Requirement: AGE-Authoritative Topology Context for Overlays
Causal overlay evaluation SHALL consume the Dgraph canonical topology context and SHALL NOT depend on UI-side identity fusion for adjacency reasoning.

#### Scenario: Overlay evaluation uses canonical graph context
- **GIVEN** canonical topology edges are projected in Dgraph
- **WHEN** causal overlay evaluation executes
- **THEN** adjacency reasoning SHALL use the Dgraph canonical topology context
- **AND** overlay state SHALL remain aligned with canonical topology projections

#### Scenario: Unresolved endpoints do not trigger identity collapse
- **GIVEN** causal signals reference endpoints that are unresolved in canonical identity
- **WHEN** overlay state is computed
- **THEN** unresolved references SHALL remain explicit
- **AND** the system SHALL NOT merge identities based only on adjacency heuristics
