## ADDED Requirements

### Requirement: Endpoint Inventory Does Not Expand AGE Package Graph
Endpoint inventory SHALL NOT create package vertices or package membership edges in the AGE topology graph.

#### Scenario: Package membership remains relational
- **GIVEN** endpoint inventory ingestion normalizes package rows
- **WHEN** topology graph projection runs
- **THEN** it SHALL NOT create `Package` vertices
- **AND** it SHALL NOT create `HAS_PACKAGE` or `AFFECTED_BY` edges in `platform_graph`

#### Scenario: Device risk summary uses bounded scalar properties
- **GIVEN** endpoint vulnerability risk summary changes for a canonical device
- **WHEN** the AGE topology graph is updated
- **THEN** only a bounded fixed set of scalar risk-summary properties MAY be set on the existing `Device` vertex
- **AND** the update SHALL NOT change topology adjacency

#### Scenario: Missing device vertex does not create package subgraph
- **GIVEN** endpoint inventory exists for a device whose AGE `Device` vertex has not yet been projected
- **WHEN** risk summary projection runs
- **THEN** it MAY create or merge only the canonical `Device` vertex if that is the established device projection behavior
- **AND** it SHALL NOT create package vertices or package edges
