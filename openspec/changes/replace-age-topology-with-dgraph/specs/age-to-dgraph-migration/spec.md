## ADDED Requirements

### Requirement: Rebuild-from-evidence migrator
The system SHALL provide a Bazel-built `age-to-dgraph` binary that rebuilds the Dgraph topology graph from current mapper evidence tables.

#### Scenario: Rebuild is the default mode
- **WHEN** the migrator Job runs without an explicit mode
- **THEN** it rebuilds canonical Dgraph edges from relational evidence
- **AND** it does not treat the AGE dump as the source of truth

#### Scenario: Rebuild is idempotent
- **WHEN** the migrator rebuilds twice against an unchanged evidence set
- **THEN** the second run reports no additional canonical edges
- **AND** `topo.link_key` cardinality is unchanged

### Requirement: Checksum against AGE
The system SHALL compare AGE `platform_graph` and Dgraph topology after a rebuild and fail the Job when they disagree beyond the documented tolerance.

#### Scenario: Matching graphs pass
- **GIVEN** dual-write has projected the same evidence into AGE and Dgraph
- **WHEN** checksum runs
- **THEN** node counts, canonical-edge counts, and the canonical-edge content hash agree
- **AND** the Job succeeds

#### Scenario: Divergence fails the Job
- **GIVEN** Dgraph is missing canonical edges that AGE has
- **WHEN** checksum runs
- **THEN** the Job fails
- **AND** `GRAPH_READ` is not flipped to Dgraph

### Requirement: Bundle delivery
The system SHALL ship the migrator as part of the ServiceRadar image bundle and invoke it from Helm and Docker Compose, not from a new script under `scripts/`.

#### Scenario: Helm Job
- **WHEN** Helm upgrade runs with Dgraph enabled
- **THEN** a Job runs the Bazel-built migrator image
- **AND** a checksum failure fails the upgrade

#### Scenario: Compose one-shot
- **WHEN** Docker Compose starts with Dgraph
- **THEN** a one-shot applies schema and can rebuild from local evidence
- **AND** no operator shell script is required

### Requirement: Operator-safe Dgraph reset
The system SHALL provide an operator-safe workflow to clear a polluted Dgraph topology and rebuild it from fresh observations.

#### Scenario: Cleanup and rebuild produces bounded graph state
- **GIVEN** topology evidence is reset using the documented workflow
- **WHEN** fresh discovery jobs run and the migrator rebuilds Dgraph
- **THEN** rebuilt Dgraph adjacency is derived only from post-reset evidence
- **AND** validation queries report pre/post counts and unresolved endpoint totals

### Requirement: Synthetic fixtures only
The system SHALL use invented topology fixtures in tests, docs, and examples; captured live AGE dumps SHALL NOT enter the repository.

#### Scenario: Fixture is synthetic
- **WHEN** a migrator unit test loads a graph
- **THEN** hostnames, IPs, MACs, and site identifiers are documentation/reserved values
- **AND** the fixture is not an export from a running deployment
