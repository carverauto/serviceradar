## ADDED Requirements

### Requirement: AGE dual-write shadow during Dgraph cutover
The system SHALL continue to project topology into Apache AGE while `GRAPH_BACKEND` is `age` or `dual`, and SHALL stop projecting into AGE when `GRAPH_BACKEND=dgraph`.

#### Scenario: Shadow writes while dual
- **GIVEN** `GRAPH_BACKEND=dual`
- **WHEN** mapper topology is projected
- **THEN** AGE `platform_graph` receives the same logical upserts it does today
- **AND** Dgraph receives the corresponding `TopologyEdge` projection

#### Scenario: AGE writes stop
- **GIVEN** `GRAPH_BACKEND=dgraph`
- **WHEN** mapper topology is projected
- **THEN** no new Cypher mutations are issued against `platform_graph`

## MODIFIED Requirements

### Requirement: AGE-authoritative topology read model
The system SHALL treat canonical Apache AGE topology edges as the authoritative source for topology rendering and downstream graph consumers only while `GRAPH_READ=age`. Once `GRAPH_READ=dgraph`, Dgraph canonical edges SHALL be the authoritative source and AGE SHALL NOT be consulted for topology rendering.

#### Scenario: Renderer consumes canonical AGE edges
- **GIVEN** canonical topology edges are projected in AGE
- **AND** `GRAPH_READ=age`
- **WHEN** web topology views are generated
- **THEN** edge construction SHALL use canonical AGE adjacency
- **AND** rendering SHALL NOT require additional identity-fusion heuristics in the UI layer

#### Scenario: Renderer switches to Dgraph after cutover
- **GIVEN** `GRAPH_READ=dgraph`
- **WHEN** web topology views are generated
- **THEN** edge construction SHALL use canonical Dgraph adjacency
- **AND** AGE SHALL NOT be queried for those views
