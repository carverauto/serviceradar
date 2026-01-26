## ADDED Requirements

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
