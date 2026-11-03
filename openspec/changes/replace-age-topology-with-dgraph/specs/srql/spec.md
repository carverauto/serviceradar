## ADDED Requirements

### Requirement: Dgraph graph entity
The SRQL service SHALL support `in:graph` (alias `graph_dql`) that executes read-only DQL against Dgraph and returns rows in the `{nodes, edges}` wrapper owned by the `dgraph-topology` crate, so the Rust engine and the web-ng query surface emit the same rows.

#### Scenario: Read-only DQL executes
- **GIVEN** `GRAPH_READ=dgraph` and a populated topology
- **WHEN** a client sends `in:graph` with a read-only DQL body
- **THEN** SRQL returns rows wrapped as `{nodes, edges}`
- **AND** the query does not touch Apache AGE

#### Scenario: The web query surface executes it against Dgraph
- **WHEN** a client sends `in:graph` with a read-only DQL body through the query bar, the query API or MCP
- **THEN** the query runs against Dgraph rather than failing SQL translation
- **AND** without a configured Dgraph endpoint the client receives an error that names Dgraph, not empty results

#### Scenario: Mutations are refused
- **WHEN** a client sends `in:graph` with a mutation
- **THEN** SRQL returns an error
- **AND** no mutation is submitted to Dgraph

### Requirement: graph_cypher is retired with Apache AGE
The SRQL service SHALL reject `in:graph_cypher` (and its `graphcypher` / `cypher` aliases) with a client error that names `in:graph` as the replacement, and SHALL NOT execute Cypher against Apache AGE.

#### Scenario: Cypher is refused
- **WHEN** a client sends `in:graph_cypher cypher:"..."`
- **THEN** SRQL returns an invalid-request error that names `in:graph dql:`
- **AND** no query is issued against Postgres or AGE

### Requirement: Device neighborhood reads Dgraph
The SRQL service SHALL answer `in:device_graph device_id:"..."` from the Dgraph topology graph, returning the device, its interfaces, and the peer interfaces its current `CONNECTS_TO` evidence reaches, and SHALL return an invalid-request error when no Dgraph endpoint is configured.

The topology graph holds no collector, service or capability vertices, so those arrays are empty and `collector_owned:true` is refused rather than answered with nothing.

#### Scenario: Neighborhood from Dgraph
- **GIVEN** a Device with interfaces and `CONNECTS_TO` edges to two peers in Dgraph
- **WHEN** a client sends `in:device_graph device_id:"<id>"`
- **THEN** the single result carries the device, its interfaces and both peer interfaces with their owning device
- **AND** `include_topology:false` returns the device with empty interface arrays

#### Scenario: Dgraph not configured
- **GIVEN** no `DGRAPH_URL`
- **WHEN** a client sends `in:device_graph device_id:"<id>"`
- **THEN** SRQL returns an invalid-request error naming `DGRAPH_URL`

#### Scenario: The web query surface executes it against Dgraph
- **WHEN** a client sends `in:device_graph device_id:"<id>"` through the query bar, the query API or MCP
- **THEN** the neighborhood is read from Dgraph with the same `device_id`, `include_topology` and `collector_owned` validation
- **AND** without a configured Dgraph endpoint the client receives an error that names Dgraph, not empty results
