## MODIFIED Requirements
### Requirement: CNPG Postgres image ships TimescaleDB, Apache AGE, pg_trgm, and PostGIS
ServiceRadar MUST publish a CNPG-compatible Postgres image that bundles the TimescaleDB, Apache AGE, pg_trgm, and PostGIS extensions so clusters can enable analytics and geospatial capabilities without manual package installs.

#### Scenario: PostGIS extension loads successfully
- **GIVEN** the custom image tag `ghcr.io/carverauto/serviceradar-cnpg:<version>`
- **WHEN** a pod starts from that image and `psql` runs `CREATE EXTENSION IF NOT EXISTS postgis;`
- **THEN** the command succeeds without downloading OS packages at runtime.

#### Scenario: PostGIS runtime reports a valid version
- **GIVEN** a running CNPG cluster using the custom image
- **WHEN** `SELECT postgis_full_version();` is executed
- **THEN** the query returns a non-empty PostGIS version string.

### Requirement: SPIRE CNPG cluster uses the custom image
The SPIRE CNPG deployment (demo kustomize manifests and Helm chart) MUST consume the custom image and initialize required extensions in the target database(s).

#### Scenario: Demo kustomize deployment
- **GIVEN** `kubectl apply -k k8s/demo/base/spire`
- **WHEN** the `cnpg` pods become Ready
- **THEN** their container image is the published custom tag
- **AND** `SELECT extname FROM pg_extension` in the initialized database lists `timescaledb`, `age`, and `postgis`.

#### Scenario: Helm values deployment
- **GIVEN** `helm template serviceradar ./helm/serviceradar --set spire.enabled=true --set spire.postgres.enabled=true`
- **WHEN** the rendered CNPG manifest is inspected
- **THEN** it references the same custom image
- **AND** extension bootstrap SQL includes `CREATE EXTENSION IF NOT EXISTS postgis;` for the configured database.
