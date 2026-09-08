## ADDED Requirements

### Requirement: Fresh installs use a schema baseline
ServiceRadar SHALL bootstrap a proven-empty platform database from a canonical current-schema baseline instead of replaying historical upgrade migrations.

#### Scenario: Clean Docker Compose install uses baseline
- **GIVEN** a Docker Compose deployment with no existing CNPG data volume
- **WHEN** the stack starts and the core migration bootstrap runs
- **THEN** the platform schema is created from the current baseline
- **AND** historical migrations included in the baseline are marked as applied
- **AND** core-dependent services are not blocked by replaying the historical migration chain.

#### Scenario: Clean Helm install uses baseline
- **GIVEN** a Helm deployment with a newly initialized ServiceRadar database
- **WHEN** the migration/bootstrap job runs
- **THEN** the platform schema is created from the current baseline
- **AND** historical migrations included in the baseline are marked as applied
- **AND** workload pods start against the baseline-created schema.

### Requirement: Existing deployments continue to run upgrade migrations
ServiceRadar SHALL run pending migrations normally when a database already has coherent migration history.

#### Scenario: Upgrade from migrated database
- **GIVEN** a database with platform migration ledger rows from a prior ServiceRadar version
- **WHEN** a newer ServiceRadar version starts
- **THEN** only migrations newer than the recorded migration state run
- **AND** the baseline is not applied over existing platform objects.

### Requirement: Ambiguous database state fails closed
ServiceRadar SHALL refuse automatic bootstrap when platform objects exist without coherent migration metadata.

#### Scenario: Partial database without migration ledger
- **GIVEN** a database containing ServiceRadar platform objects
- **AND** the migration ledger is missing or inconsistent
- **WHEN** the migration/bootstrap job runs
- **THEN** startup fails before applying the baseline or pending migrations
- **AND** the error explains how to repair or restore the database.

### Requirement: Baseline matches migration replay
The committed baseline SHALL be validated against the schema produced by replaying supported migrations on an empty database.

#### Scenario: CI compares baseline and replay schemas
- **GIVEN** CI creates one database from the baseline
- **AND** CI creates another database by replaying the supported migration chain
- **WHEN** the schema diff validation runs
- **THEN** user-owned platform schema objects, indexes, constraints, views, continuous aggregates, policies, and grants match
- **AND** extension-owned catalog differences are ignored only by explicit allowlist.

### Requirement: Operational data work is outside first-boot readiness
ServiceRadar SHALL NOT require data backfills, cleanup updates, continuous aggregate refreshes, or repair jobs to complete before a fresh empty database installation becomes ready.

#### Scenario: Empty database skips blocking backfills
- **GIVEN** a clean install with no product data
- **WHEN** the database bootstrap completes
- **THEN** service readiness does not wait for historical backfills, cleanup updates, or continuous aggregate refreshes
- **AND** any required maintenance is scheduled or documented as idempotent post-bootstrap work.

### Requirement: Clean-install bootstrap time is bounded
ServiceRadar SHALL enforce a bounded clean-install database bootstrap target in automated verification.

#### Scenario: Compose smoke test enforces startup window
- **GIVEN** CI runs `docker compose down -v`
- **WHEN** CI starts the Docker Compose stack
- **THEN** CNPG, core, web-ng, and required dependent services reach healthy state within the configured clean-install startup window
- **AND** migration/bootstrap logs show the baseline path was used.
