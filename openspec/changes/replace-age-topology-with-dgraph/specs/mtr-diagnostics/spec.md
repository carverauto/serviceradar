## MODIFIED Requirements

### Requirement: Apache AGE Path Projection
The core system SHALL project MTR trace paths into the Dgraph topology graph as `MTR_PATH` edges between vertices, correlating hop IPs with existing Device vertices when possible and creating HopNode vertices for unknown hops.

#### Scenario: Path projected into Dgraph
- **WHEN** an MTR trace is ingested
- **THEN** for each consecutive hop pair, a `MTR_PATH` TopologyEdge is upserted in Dgraph with the far hop's latency, loss, jitter and hop numbers
- **AND** hop IPs matching existing Device nodes reuse those nodes
- **AND** hop IPs not matching any Device get a HopNode
- **AND** no Cypher is issued against Apache AGE

#### Scenario: Stale path pruning
- **WHEN** an `MTR_PATH` edge has not been updated within the configured TTL (default 24 hours)
- **THEN** the edge is removed from Dgraph during the next pruning cycle

## ADDED Requirements

### Requirement: MTR path overlays read Dgraph
The web UI SHALL read MTR path overlays (dashboard map, full-screen NetFlow map, and God View) from `MTR_PATH` edges in the Dgraph topology graph, including each segment's average latency, loss, jitter and hop numbers, and SHALL show an unavailable notice instead of an empty overlay when the graph read fails.

#### Scenario: Overlay carries path measurements
- **GIVEN** an MTR trace whose second hop reports 4.25 ms average latency and 12.5% loss
- **WHEN** the trace is projected and the dashboard map loads
- **THEN** the overlay segment ending at that hop carries those measurements

#### Scenario: Graph read fails
- **GIVEN** Dgraph cannot be read
- **WHEN** the dashboard map or God View loads MTR overlays
- **THEN** the page states that MTR path overlays are unavailable
- **AND** it does not present the failure as zero paths
