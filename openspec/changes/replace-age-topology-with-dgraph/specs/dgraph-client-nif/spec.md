## ADDED Requirements

### Requirement: Shared Rust Dgraph client
The system SHALL talk to Dgraph from Rust through `dgraph-client` from `marvin-hansen/dgraph-rs`, not through a second in-repo client and not through a Hex/Elixir driver.

#### Scenario: Single client crate
- **WHEN** ServiceRadar opens a Dgraph connection
- **THEN** the caller is `dgraph_client::DgraphClient`
- **AND** no crate at `rust/dgraph-client` is required in this repository

#### Scenario: Workspace pin
- **WHEN** the dependency is declared
- **THEN** its version (or git pin) lives in `[workspace.dependencies]`
- **AND** `cargo check` of a consuming crate passes standalone
- **AND** the Bazel target for that crate builds

### Requirement: Shared schema migrator
The system SHALL apply, verify, and remove Dgraph schemas through a shared `dgraph-migrate` crate extracted from scrith's generic runner.

#### Scenario: Verify first
- **WHEN** a schema Job starts
- **THEN** it verifies the expected predicates and types
- **AND** it applies the schema only when verification reports a miss
- **AND** an already-current cluster is reported as current, not as migrated

#### Scenario: Scoped remove
- **WHEN** deprovision is requested with confirmation
- **THEN** only the named topology predicates and types are dropped
- **AND** `drop_all` is not invoked

#### Scenario: Shared cluster confirm
- **WHEN** deprovision is requested against a non-local environment without the confirm value
- **THEN** the operation is refused
- **AND** existing predicates remain

### Requirement: Elixir NIF facade
The system SHALL expose Dgraph to Elixir only through a Rustler NIF wrapping `dgraph-topology`, with typed write operations and a read-only DQL escape hatch.

#### Scenario: Typed write
- **WHEN** topology code upserts a canonical edge
- **THEN** the call is a typed NIF operation
- **AND** Elixir does not concatenate DQL for the write

#### Scenario: Mutation hatch refused
- **WHEN** the DQL escape hatch is invoked with a mutation
- **THEN** the NIF returns an error
- **AND** no mutation is submitted to Dgraph

#### Scenario: Scheduler isolation
- **WHEN** a NIF call panics
- **THEN** the DirtyIo scheduler thread is not killed
- **AND** the Elixir caller receives `{:error, _}`

### Requirement: Self-cluster credentials
The system SHALL supply Dgraph ACL credentials as ServiceRadar-to-self configuration (environment, Kubernetes Secret, or Docker secret), not through `network_credential_secrets`.

#### Scenario: Secret stays out of values
- **WHEN** Helm is rendered
- **THEN** the ACL password is referenced as a Secret
- **AND** it is not inlined in chart values
