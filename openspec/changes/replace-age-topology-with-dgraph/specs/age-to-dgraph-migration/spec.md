## ADDED Requirements

### Requirement: Operator-safe Dgraph reset
The system SHALL provide an operator-safe workflow to clear a polluted Dgraph topology and rebuild it from fresh observations through core's canonical reconciliation, never through `drop_all`.

#### Scenario: Cleanup and rebuild produces bounded graph state
- **GIVEN** topology evidence is reset using the documented workflow
- **WHEN** fresh discovery jobs run and canonical reconciliation runs against Dgraph
- **THEN** rebuilt Dgraph adjacency is derived only from post-reset evidence
- **AND** no Dgraph predicate outside the topology namespace is touched

### Requirement: Synthetic fixtures only
The system SHALL use invented topology fixtures in tests, docs, and examples; captured live graph dumps SHALL NOT enter the repository.

#### Scenario: Fixture is synthetic
- **WHEN** a topology test loads a graph
- **THEN** hostnames, IPs, MACs, and site identifiers are documentation/reserved values
- **AND** the fixture is not an export from a running deployment
