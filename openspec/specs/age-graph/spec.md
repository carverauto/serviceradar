# age-graph Specification

## Purpose
TBD - created by archiving change fix-core-elx-agtype-handling. Update Purpose after archive.
## Requirements
### Requirement: AGE Query Execution
The system SHALL execute Apache AGE Cypher queries through Postgrex without type handling errors.

#### Scenario: Interface graph upsert succeeds
- **WHEN** TopologyGraph receives interface data from mapper
- **THEN** the interface node is created/updated in the AGE graph
- **AND** no Postgrex type errors occur

#### Scenario: Link graph upsert succeeds
- **WHEN** TopologyGraph receives link data from mapper
- **THEN** the device and interface nodes are created/updated
- **AND** the CONNECTS_TO relationship is established
- **AND** no Postgrex type errors occur

### Requirement: AGE Result Type Handling
The system SHALL convert AGE agtype results to text format before returning from Postgrex queries.

#### Scenario: Agtype converted to text
- **WHEN** a Cypher query returns agtype values
- **THEN** the results are converted using `ag_catalog.agtype_to_text()`
- **AND** Postgrex successfully decodes the text result

### Requirement: Canonical AGE graph schema access
The system SHALL create and use the `platform_graph` AGE graph for topology projections in a dedicated schema, and the application role SHALL have USAGE/CREATE/ALL privileges on the `platform_graph` schema and own the AGE label tables.

#### Scenario: Graph schema privileges applied
- **GIVEN** the `platform_graph` schema exists and the AGE graph tables are owned by a superuser
- **WHEN** core-elx runs startup migrations
- **THEN** the `serviceradar` role has USAGE/CREATE and ALL on schema `platform_graph`
- **AND** the `serviceradar` role owns AGE label tables in `platform_graph`

#### Scenario: Topology projections target the canonical graph
- **GIVEN** mapper interface or topology data
- **WHEN** projections run
- **THEN** Cypher queries target graph `platform_graph`
- **AND** graph upserts complete without schema permission errors

