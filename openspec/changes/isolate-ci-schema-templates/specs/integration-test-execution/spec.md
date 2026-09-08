## ADDED Requirements

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
