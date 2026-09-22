## ADDED Requirements

### Requirement: Dgraph graph entity
The SRQL service SHALL support `in:graph` (alias `graph_dql`) that executes read-only DQL against Dgraph and returns the same `{nodes, edges}` wrapper as `graph_cypher`.

#### Scenario: Read-only DQL executes
- **GIVEN** `GRAPH_READ=dgraph` and a populated topology
- **WHEN** a client sends `in:graph` with a read-only DQL body
- **THEN** SRQL returns rows wrapped as `{nodes, edges}`
- **AND** the query does not touch Apache AGE

#### Scenario: Mutations are refused
- **WHEN** a client sends `in:graph` with a mutation
- **THEN** SRQL returns an error
- **AND** no mutation is submitted to Dgraph

### Requirement: graph_cypher remains during dual-read
The SRQL service SHALL keep `in:graph_cypher` executing read-only Cypher against AGE while AGE remains deployed.

#### Scenario: Cypher still works during cutover
- **GIVEN** AGE `platform_graph` still exists
- **WHEN** a client sends `in:graph_cypher`
- **THEN** SRQL executes the Cypher against AGE
- **AND** mutations remain rejected
