## ADDED Requirements

### Requirement: Docker Compose CNPG major-version mismatch fails fast
The Docker Compose stack MUST detect when the mounted CNPG data volume was
initialized by a different Postgres major version than the configured CNPG
image and MUST stop before starting Postgres with an actionable migration
message.

#### Scenario: PG16 data volume on PG18 image
- **GIVEN** a Docker Compose `cnpg-data` volume whose `PG_VERSION` file reports PostgreSQL 16
- **AND** the Compose stack targets a PostgreSQL 18 CNPG image
- **WHEN** the `cnpg` service starts
- **THEN** the stack exits before Postgres boots on that data directory
- **AND** the error message explains that Docker Compose does not perform major upgrades automatically
- **AND** the error message points the operator to the supported migration workflow

### Requirement: Docker Compose provides a controlled CNPG PG16-to-PG18 migration workflow
The Docker Compose stack MUST provide a supported workflow for migrating an
existing PG16 CNPG local volume to a PG18-compatible local volume without
requiring manual schema repair after the upgrade.

#### Scenario: Existing local CNPG volume is migrated to PG18
- **GIVEN** a Docker Compose install with a persisted PG16 `cnpg-data` volume
- **WHEN** the operator runs the documented Compose PG16-to-PG18 migration workflow
- **THEN** the workflow produces a PG18-compatible CNPG data volume
- **AND** ServiceRadar application data is preserved
- **AND** the Compose stack can start successfully on PG18 after the migration completes

### Requirement: Docker Compose migration preserves effective database credentials
The Docker Compose CNPG migration workflow MUST preserve the effective
superuser and application credential state needed by the upgraded
stack, including legacy installs that predate the dedicated credentials volume.

#### Scenario: Legacy install without persisted credentials migrates successfully
- **GIVEN** a Docker Compose install with a PG16 CNPG data volume and no persisted `cnpg-credentials` volume
- **AND** the install previously used the legacy Compose credential defaults
- **WHEN** the operator runs the Compose PG16-to-PG18 migration workflow
- **THEN** the migrated stack starts with credentials that match the effective legacy install state
- **AND** core/web-ng/CNPG connections succeed without requiring manual password resets
