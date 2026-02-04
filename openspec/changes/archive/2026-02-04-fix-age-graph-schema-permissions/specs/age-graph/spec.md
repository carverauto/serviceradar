## ADDED Requirements
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
