# integration-test-execution Specification

## Purpose

Define schema-input isolation, immutable template publication, generation pinning, and guarded cleanup for CI database integration lifecycles.
## Requirements
### Requirement: Template identity follows declared schema inputs

The integration lifecycle SHALL select templates using a canonical versioned manifest covering migration paths and contents, baseline inputs, and schema-affecting construction dependencies and configuration. Rust and Elixir SHALL consume the same declared manifest. Fixture compatibility SHALL be checked before reuse.

#### Scenario: Divergent checkouts run concurrently
- **WHEN** two checkouts with divergent migration inputs prepare and clone concurrently
- **THEN** each SHALL receive a template and clones matching its own expected schema and migration history
- **AND** neither SHALL advance or block the other by introducing extra applied migrations.

#### Scenario: Applied migration content changes
- **WHEN** a migration changes without changing its version
- **THEN** the manifest identity SHALL change
- **AND** the previous generation SHALL NOT satisfy the new request
- **AND** inconsistent baseline coverage SHALL fail explicitly before publication.

#### Scenario: Identical inputs on different branches
- **WHEN** branches have identical declared inputs and compatible fixture versions
- **THEN** they SHALL reuse the same ready generation without invoking the migrator.

### Requirement: Only complete immutable template generations are cloneable

The lifecycle SHALL construct private candidates and publish a generation only after verifying its manifest, expected migration history, and initialization. Published generations MUST NOT be migrated in place. Concurrent builders SHALL use bounded ownership coordination and fencing.

#### Scenario: Builder fails during migration
- **WHEN** a builder exits before publication
- **THEN** its candidate SHALL remain unavailable to cloning
- **AND** recovery SHALL affect only that owned candidate
- **AND** another ready generation SHALL remain usable.

#### Scenario: Competing builders and stale publication
- **WHEN** builders request the same manifest or an expired builder resumes
- **THEN** only the current owner SHALL publish
- **AND** competitors SHALL reuse the verified result or fail with an explicit bounded timeout.

### Requirement: Generation pinning and cleanup preserve active runs

A run SHALL pin its generation through preparation and cloning. Cleanup SHALL synchronize with acquisition and cloning, enforce retention/resource bounds, and delete only registered inactive generations. Ordinary teardown MUST NOT delete template generations or protected databases.

#### Scenario: Cleanup races with cloning
- **WHEN** a leased generation is being cloned while cleanup runs
- **THEN** cleanup SHALL NOT drop that generation
- **AND** cloning SHALL revalidate readiness under the generation coordination lock.

#### Scenario: Abandoned generation and capacity limit
- **WHEN** a registered generation has expired leases, no live builder or connections, and meets retention rules
- **THEN** guarded cleanup MAY remove that exact generation
- **AND** insufficient reclaimable capacity SHALL produce an explicit failure without deleting active generations.

### Requirement: Template isolation retains the guarded CI execution boundary

Template lifecycle actions SHALL use typed fixture configuration and declared Bazel inputs, retain TLS and protected database guards, and execute database qualification inside the in-cluster workflow. Cold construction SHALL pass before rollout; warm reuse SHALL avoid migration startup. Preflight SHALL remain outside measured suite timing.

#### Scenario: Cold construction fails
- **WHEN** cold schema construction fails with lock exhaustion or another initialization error
- **THEN** the run SHALL report a template construction failure before suite execution
- **AND** no candidate SHALL be published
- **AND** the result SHALL NOT be reported as successful test qualification.

#### Scenario: Preflight and measured run have different identifiers
- **WHEN** the workflow enters its measured lifecycle after successful preflight
- **THEN** it SHALL retain the same manifest-selected generation
- **AND** it SHALL fail explicitly if that generation is unavailable
- **AND** it SHALL NOT fall back to the legacy shared template.

### Requirement: The shared mutable template lifecycle is retired

The integration lifecycle SHALL NOT define or invoke any target that creates, migrates, resets, or
clones from a shared mutable template database, and SHALL NOT define a build setting that
authorizes writes to one. Manifest-selected immutable generations SHALL be the only template
source for integration databases. A contract test SHALL fail if a retired target, the retired
authority setting, or a retired lifecycle source file is reintroduced.

The retired targets are `//elixir/serviceradar_core:migrate_template`,
`//elixir/serviceradar_core:migrate_run`, `//rust/integration-db:prepare_template`,
`//rust/integration-db:reset_template`, `//rust/integration-db:provision_base`,
`//rust/integration-db:provision_db`, `//rust/integration-db:provision_db_large_ingestion`, and
the per-lane `//rust/integration-db:provision_db_<lane>` targets. The retired setting is
`//build:template_authority` with its marker file target.

#### Scenario: Retired targets do not resolve
- **WHEN** a caller queries or invokes any retired target or `//build:template_authority`
- **THEN** Bazel SHALL report that no such target exists
- **AND** no workflow action SHALL name any retired target or the retired setting

#### Scenario: Reintroduction is caught
- **GIVEN** a change adds a BUILD rule named after a retired target, restores the authority
  setting, or restores a retired lifecycle source file
- **WHEN** the repository contract tests run
- **THEN** the retired-names contract SHALL fail and name the reintroduced item

#### Scenario: No path recreates the singleton
- **GIVEN** the fixture has no `sr_core_template` database
- **WHEN** any integration lifecycle target runs, from CI or a workstation
- **THEN** no target SHALL create a database named `sr_core_template`
- **AND** every lane database SHALL be cloned from the run's pinned generation

### Requirement: Focused lane provisioning uses template generations

The lifecycle SHALL provide one focused clone target per integration lane, generated from the same
lane list as the Elixir lane test targets, that clones only that lane's disposable database from
the run's pinned template generation.

#### Scenario: Developer runs one lane
- **GIVEN** a developer mints one run id and runs `prepare_generation`, then
  `migrate_generation` when preparation reports `needs_migration`, then `prepare_generation`
  again until it reports `ready`
- **WHEN** the developer runs `provision_generation_<lane>` followed by the matching
  `integration_tests_<lane>` target
- **THEN** only `sr_core_test_<run>_<lane>` SHALL be created, from the pinned generation
- **AND** `release_generation` and `teardown_db` SHALL release the lease and drop that database

#### Scenario: Lane set drifts
- **WHEN** a lane is added to or removed from the canonical lane list
- **THEN** the focused generation clone targets SHALL change with it, with no hand-maintained list

### Requirement: The test database guard admits only generation templates

The Elixir test database guard SHALL grant template lifecycle access only to a database named
`sr_tpl_` followed by exactly 48 lowercase hexadecimal characters that matches the authorized
generation, and SHALL reject `sr_core_template` in every mode.

#### Scenario: Singleton rejected under template lifecycle
- **WHEN** a caller attempts to authorize or validate `sr_core_template`, with or without the
  template lifecycle option
- **THEN** the guard SHALL raise before Repo startup

#### Scenario: Selected generation accepted
- **GIVEN** the guard has authorized one manifest-selected generation
- **WHEN** a caller validates that generation with the template lifecycle option
- **THEN** the guard SHALL accept it
- **AND** it SHALL reject any other `sr_tpl_` name

### Requirement: The legacy template database is removed only after approval and verification

Removal of the `sr_core_template` database from the `srql-fixtures` cluster SHALL happen only
after the retired lifecycle code is on trunk and trunk CI is green, SHALL require explicit
approval from the user, and SHALL be verified by re-querying the fixture after the next CI
lifecycles and reaper pass. Until that verification, every protected-name list (the Rust stale
sweep, the Go reaper, the scratch-reaper SQL and ConfigMap, and their deployed copies) SHALL
continue to protect `sr_core_template`, so no age-based reaper can drop it.

#### Scenario: Code retired but drop not yet approved
- **GIVEN** the retired lifecycle code has merged and the user has not approved the drop
- **WHEN** `sweep_stale_dbs`, the Go reaper, or the scratch-reaper CronJob runs
- **THEN** `sr_core_template` SHALL NOT be dropped
- **AND** no integration lifecycle SHALL connect to it

#### Scenario: Approved drop is verified before protection is removed
- **GIVEN** the user has approved the drop and the pre-checks passed
- **WHEN** the database has been dropped
- **THEN** it SHALL be absent immediately, after the next BazelCI and LargeIngestionGate
  lifecycles, and after the next scratch-reaper pass
- **AND** only then SHALL the name be removed from every protected-name list and mirror together
- **AND** the `sr_tpl_` namespace protection SHALL remain

#### Scenario: Drop declined
- **WHEN** the user declines the drop
- **THEN** the database SHALL remain frozen and protected
- **AND** no retired lifecycle code SHALL be restored to use it

