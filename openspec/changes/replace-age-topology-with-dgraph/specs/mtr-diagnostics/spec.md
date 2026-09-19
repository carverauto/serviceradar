## MODIFIED Requirements

### Requirement: Apache AGE Path Projection
The core system SHALL project MTR trace paths into the configured graph backend as `MTR_PATH` edges between vertices, correlating hop IPs with existing Device vertices when possible and creating HopNode vertices for unknown hops. While `GRAPH_BACKEND` is `age` or `dual`, AGE `platform_graph` SHALL receive the projection; while `GRAPH_BACKEND` is `dual` or `dgraph`, Dgraph SHALL receive the projection.

#### Scenario: Path projected into AGE graph
- **GIVEN** `GRAPH_BACKEND` is `age` or `dual`
- **WHEN** an MTR trace is ingested
- **THEN** for each consecutive hop pair, a `MTR_PATH` edge is created/updated in `platform_graph`
- **AND** hop IPs matching existing Device vertices reuse those vertices
- **AND** hop IPs not matching any Device get a HopNode vertex

#### Scenario: Path projected into Dgraph
- **GIVEN** `GRAPH_BACKEND` is `dual` or `dgraph`
- **WHEN** an MTR trace is ingested
- **THEN** for each consecutive hop pair, a `MTR_PATH` TopologyEdge is upserted in Dgraph
- **AND** hop IPs matching existing Device nodes reuse those nodes
- **AND** hop IPs not matching any Device get a HopNode

#### Scenario: Stale path pruning
- **WHEN** an `MTR_PATH` edge has not been updated within the configured TTL (default 24 hours)
- **THEN** the edge is removed from the active graph backend during the next pruning cycle
