## ADDED Requirements

### Requirement: Every migration entry point bootstraps from the schema baseline
Bringing a database up to date SHALL apply the schema baseline to a proven-empty database
regardless of which entry point performs the migration. This SHALL hold for service startup, for
the CI fixture template preparation, and for the documented developer migration task.

#### Scenario: CI fixture template bootstraps from the baseline
- **GIVEN** an empty template database
- **WHEN** the fixture template migration target runs
- **THEN** the platform schema SHALL be created from the committed baseline
- **AND** every migration version included in the baseline SHALL be recorded as applied without
  that migration executing
- **AND** only migrations newer than the baseline SHALL execute

#### Scenario: Developer migration task bootstraps from the baseline
- **GIVEN** a developer with an empty scratch database
- **WHEN** they run the documented ServiceRadar migration task
- **THEN** the database SHALL be brought current from the baseline plus pending migrations
- **AND** the historical migrations contained in the baseline SHALL NOT execute

#### Scenario: Database with existing history is unaffected
- **GIVEN** a database with coherent migration history
- **WHEN** any migration entry point runs
- **THEN** the baseline SHALL NOT be applied
- **AND** only pending migrations SHALL execute

### Requirement: A single bootstrap implementation serves every entry point
The empty/migrated/ambiguous classification and the baseline application SHALL exist in exactly
one implementation, taking the repository as an argument, and every entry point SHALL call it.
No entry point SHALL carry its own copy of that logic, in any language.

#### Scenario: Startup and migrator paths share one implementation
- **WHEN** service startup and the migrator-driven entry points each bootstrap a database
- **THEN** both SHALL reach the same classification function and the same baseline application
  function
- **AND** a change to classification behaviour SHALL take effect for both without a second edit

#### Scenario: Startup behaviour is unchanged by the extraction
- **GIVEN** the classification and baseline application have been extracted from the startup
  module
- **WHEN** the cold-start bootstrap qualification runs
- **THEN** it SHALL pass without changes to its assertions

### Requirement: Migrations do not relocate the migration ledger tables
A migration SHALL NOT take an exclusive lock on a migration ledger table that the running
repository reads or writes. Schema-relocation migrations SHALL exclude the ledger table named by
the repository's configured `migration_source` as well as the default `schema_migrations`, and
SHALL rely on the bootstrap path's existing creation of those tables in the platform schema
instead. The exclusion SHALL be derived from repository configuration, never from a hardcoded
table name.

#### Scenario: Schema relocation skips the configured ledger table
- **GIVEN** a repository configured with `migration_source` set to a non-default name
- **AND** a database with that ledger table present in the public schema
- **WHEN** the schema-relocation migration runs
- **THEN** it SHALL leave that table in place
- **AND** it SHALL NOT request `ACCESS EXCLUSIVE` on it
- **AND** the platform-schema ledger SHALL still be created and populated by the bootstrap path

#### Scenario: Schema relocation skips the default ledger table
- **GIVEN** a repository with no `migration_source` configured
- **WHEN** the schema-relocation migration runs
- **THEN** it SHALL leave `schema_migrations` in place

### Requirement: Schema relocation bounds and attributes every lock wait
A migration that relocates database objects SHALL bound its lock wait and SHALL, on timeout,
report which object it could not lock and which sessions held it. This SHALL apply to every
object class the migration relocates, not only tables.

#### Scenario: Blocked relocation fails fast and names the blocker
- **GIVEN** another session holds a conflicting lock on an object the migration relocates
- **WHEN** the migration attempts to relocate that object
- **THEN** it SHALL fail within the configured lock timeout rather than waiting indefinitely
- **AND** the error SHALL name the object
- **AND** the error SHALL identify the holding sessions by process id, state and query

#### Scenario: Lock timeout is scoped to the migration
- **WHEN** the migration sets its lock timeout
- **THEN** the setting SHALL apply only to that migration's transaction
- **AND** it SHALL NOT persist onto the pooled connection or affect later migrations

### Requirement: Baseline staleness is detected
The committed baseline SHALL be checked against the migrations on disk, and the check SHALL fail
when the baseline has fallen further behind than the agreed margin. A failing check SHALL state
how to regenerate the baseline.

#### Scenario: Stale baseline fails the check
- **GIVEN** migrations exist on disk newer than the baseline's recorded coverage marker by more
  than the agreed margin
- **WHEN** the baseline freshness check runs
- **THEN** it SHALL fail
- **AND** the failure SHALL report the coverage marker, the newest migration on disk, and the
  regeneration procedure

#### Scenario: Current baseline passes the check
- **GIVEN** the baseline's coverage marker is within the agreed margin of the newest migration
- **WHEN** the baseline freshness check runs
- **THEN** it SHALL pass
