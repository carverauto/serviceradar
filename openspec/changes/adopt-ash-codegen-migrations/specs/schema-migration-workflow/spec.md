# schema-migration-workflow

## ADDED Requirements

### Requirement: Committed Ash snapshots as the codegen baseline
The project SHALL commit Ash resource snapshots
(`priv/resource_snapshots/`) so that `mix ash.codegen` produces incremental
diffs rather than a from-scratch baseline migration.

#### Scenario: Snapshots are tracked
- **WHEN** the repository is checked out
- **THEN** `priv/resource_snapshots/` SHALL be present and version-controlled
  (not gitignored), and SHALL reflect the current committed schema

#### Scenario: Codegen produces a diff, not a baseline
- **WHEN** a contributor adds one new ordinary table and runs
  `mix ash.codegen <name>`
- **THEN** the generated migration SHALL contain only that table's changes,
  not a create-everything baseline

### Requirement: Codegen for ordinary relational tables
Ordinary Ash-managed relational tables SHALL have their migrations generated
by `ash.codegen`. Contributors SHALL NOT hand-write migrations for such
tables.

#### Scenario: Adding an ordinary table
- **WHEN** a new ordinary Ash-managed table is introduced
- **THEN** its migration SHALL be produced by `mix ash.codegen` and committed
  alongside the updated snapshot

### Requirement: Hand-written DDL for non-codegen-able objects
A resource backed by an object `ash.codegen` cannot represent SHALL set
`migrate? false` and be created by a hand-written migration. Such objects
include Timescale hypertables and retention policies, AGE/`ag_catalog`
objects, materialized views, continuous aggregates, triggers, and functions.

#### Scenario: Adding a hypertable
- **WHEN** a new time-series table backed by a Timescale hypertable is added
- **THEN** its resource SHALL set `migrate? false` and the hypertable +
  retention DDL SHALL be a hand-written migration, and `ash.codegen` SHALL NOT
  attempt to manage that table

#### Scenario: Mixed resource
- **WHEN** a mostly-codegen-able table also needs a raw object (special index
  or check constraint) that codegen cannot express
- **THEN** the table SHALL be codegen-managed and the raw object SHALL be a
  small hand-written follow-on migration or an AshPostgres custom block

### Requirement: Drift is caught in CI
The CI pipeline SHALL fail when Ash resources have changed without the
corresponding regenerated migration/snapshot.

#### Scenario: Forgotten codegen
- **WHEN** a pull request changes an Ash-managed resource's schema but does
  not include the regenerated migration and snapshot
- **THEN** the `mix ash.codegen --check` gate SHALL fail the build

### Requirement: pg_dump baseline remains authoritative for fresh installs
The pg_dump schema baseline used to fast-forward fresh databases SHALL remain
the fresh-install path; committing snapshots SHALL NOT change how a fresh
database is initialized.

#### Scenario: Fresh install still uses the baseline
- **WHEN** an empty platform database starts up
- **THEN** it SHALL apply the pg_dump baseline and then run only migrations
  newer than the baseline version, exactly as before this change
