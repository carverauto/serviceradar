## MODIFIED Requirements

### Requirement: CNPG Postgres image ships TimescaleDB, Apache AGE, and pg_trgm

ServiceRadar MUST publish a CNPG-compatible PostgreSQL 18 image that bundles TimescaleDB, Apache AGE, pg_trgm, and PostGIS extensions so clusters can enable analytics and geospatial capabilities without runtime package installation.

#### Scenario: PostgreSQL 18 image includes required extensions

- **GIVEN** a custom image tag `ghcr.io/carverauto/serviceradar-cnpg:<version>` built for PostgreSQL 18
- **WHEN** a pod starts from that image and executes:
  - `CREATE EXTENSION IF NOT EXISTS timescaledb;`
  - `CREATE EXTENSION IF NOT EXISTS age;`
  - `CREATE EXTENSION IF NOT EXISTS postgis;`
  - `CREATE EXTENSION IF NOT EXISTS vector;`
- **THEN** each command succeeds without downloading OS packages at runtime.

#### Scenario: Apache AGE version is PG18-compatible

- **GIVEN** a running CNPG cluster using the PostgreSQL 18 custom image
- **WHEN** `SELECT extversion FROM pg_extension WHERE extname = 'age';` is executed
- **THEN** the version returned is `1.7.x` (or newer PG18-compatible AGE release).

### Requirement: SPIRE CNPG cluster uses the custom image

The SPIRE CNPG deployment (demo kustomize manifests and Helm chart) MUST consume the PostgreSQL 18 custom image and initialize required extensions in target databases.

#### Scenario: Demo kustomize deployment uses PG18 image

- **GIVEN** `kubectl apply -k k8s/demo/base/spire`
- **WHEN** the `cnpg` pods become Ready
- **THEN** their container image is the PostgreSQL 18 custom tag
- **AND** `SELECT extname FROM pg_extension` in the initialized database lists `timescaledb`, `age`, and `postgis`.

#### Scenario: Helm values deployment uses PG18 image

- **GIVEN** `helm template serviceradar ./helm/serviceradar --set spire.enabled=true --set spire.postgres.enabled=true`
- **WHEN** the rendered CNPG manifest is inspected
- **THEN** it references the PostgreSQL 18 custom image
- **AND** extension bootstrap SQL includes `CREATE EXTENSION IF NOT EXISTS postgis;` for the configured database.

## ADDED Requirements

### Requirement: Production BM25 extension path is explicitly defined

The platform SHALL define one production BM25 extension path and one experimental path to avoid ambiguous operational ownership.

#### Scenario: Production BM25 path is ParadeDB

- **GIVEN** ServiceRadar needs PostgreSQL-native BM25 search in production
- **WHEN** operators consult ServiceRadar CNPG docs and deployment guidance
- **THEN** ParadeDB (`pg_search`) is documented as the production BM25 path
- **AND** installation/validation steps are provided for PostgreSQL 18.

#### Scenario: pg_textsearch remains experimental until GA readiness

- **GIVEN** `pg_textsearch` is available for PostgreSQL 17/18 but still in development/preview status
- **WHEN** operators review ServiceRadar extension policy
- **THEN** `pg_textsearch` is documented as experimental/non-production
- **AND** production rollout is blocked until GA stability and required limitations are resolved.
