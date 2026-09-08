## ADDED Requirements
### Requirement: Platform schema is the sole home for ServiceRadar tables
All ServiceRadar application tables, indexes, and sequences SHALL exist only in the `platform` schema (not `public`).

#### Scenario: Fresh install has no ServiceRadar tables in public
- **GIVEN** a clean docker-compose install
- **WHEN** migrations complete
- **THEN** ServiceRadar tables SHALL exist in `platform`
- **AND** there SHALL be no ServiceRadar tables in the `public` schema

### Requirement: Hypertable migrations do not depend on public search_path
Hypertable and retention migrations SHALL succeed when the database search_path is `platform, ag_catalog` by using schema-qualified TimescaleDB functions or installing TimescaleDB in a schema visible to the platform search_path.

#### Scenario: Hypertable creation succeeds with platform-only search_path
- **GIVEN** a fresh CNPG cluster with TimescaleDB enabled
- **WHEN** core-elx runs hypertable migrations with search_path set to `platform, ag_catalog`
- **THEN** `create_hypertable` calls succeed and hypertables are created

## MODIFIED Requirements
### Requirement: Core-Elx Runs Ash Migrations on Startup
The core-elx service SHALL run Ash migrations for the `platform` schema and all tenant schemas during startup, and SHALL fail startup if migrations cannot be applied.

#### Scenario: Startup migrations succeed
- **GIVEN** a core-elx instance with database access
- **WHEN** the service starts
- **THEN** Ash migrations SHALL be applied to the `platform` schema
- **AND** tenant migrations SHALL be applied to every `tenant_<tenant_slug>` schema
- **AND** the service SHALL continue startup after migrations succeed

#### Scenario: Startup migrations fail fast
- **GIVEN** a core-elx instance with database access
- **WHEN** a migration fails
- **THEN** core-elx SHALL terminate startup
- **AND** application endpoints SHALL NOT be exposed until migrations succeed
