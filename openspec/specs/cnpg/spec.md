# cnpg Specification

## Purpose
TBD - created by archiving change add-cnpg-timescale-age. Update Purpose after archive.
## Requirements
### Requirement: CNPG Postgres image ships TimescaleDB and Apache AGE
ServiceRadar MUST publish a CNPG-compatible Postgres image that bundles the TimescaleDB and Apache AGE extensions so clusters can enable both without manual package installs.

#### Scenario: Extensions load successfully
- **GIVEN** the custom image tag `ghcr.io/carverauto/serviceradar-cnpg:<version>`
- **WHEN** a pod starts from that image and `psql` runs `CREATE EXTENSION IF NOT EXISTS timescaledb; CREATE EXTENSION IF NOT EXISTS age;`
- **THEN** both commands succeed without downloading RPM/DEB packages at runtime.

#### Scenario: Shared preload libraries exported
- **GIVEN** a CNPG `Cluster` spec that references the custom image
- **WHEN** `kubectl get cluster cnpg -o yaml` renders the `postgresql.parameters.shared_preload_libraries`
- **THEN** the value contains `timescaledb,age` so the extensions can initialize.

#### Scenario: PostgreSQL version alignment
- **GIVEN** the runtime container from the custom image
- **WHEN** `psql -tAc "SHOW server_version;"` runs inside a pod
- **THEN** it reports PostgreSQL 16.6, satisfying the compatibility guidance from both TimescaleDB and Apache AGE.

### Requirement: SPIRE CNPG cluster uses the custom image
The SPIRE CNPG deployment (demo kustomize manifests and Helm chart) MUST consume the new image, initialize the `spire` database with the extensions, and expose the binaries to SPIRE pods.

#### Scenario: Demo kustomize deployment
- **GIVEN** `kubectl apply -k k8s/demo/base/spire`
- **WHEN** the `cnpg` pods become Ready
- **THEN** their container image is the published custom tag and `SELECT extname FROM pg_extension` inside the `spire` database lists both `timescaledb` and `age`.

#### Scenario: Helm values deployment
- **GIVEN** `helm template serviceradar ./helm/serviceradar --set spire.enabled=true --set spire.postgres.enabled=true`
- **WHEN** the rendered CNPG manifest is inspected
- **THEN** it references the same custom image and contains `postInitApplicationSQL` (or equivalent) that creates the `timescaledb` and `age` extensions in the configured database.

### Requirement: Clean rebuild path for SPIRE CNPG cluster
Operators MUST have a documented, testable rebuild path that deletes and recreates the SPIRE CNPG cluster with the new image, re-applies the SPIRE manifests, and validates the system from a clean slate.

#### Scenario: Recreate cluster without backups
- **GIVEN** a running SPIRE deployment on the legacy CNPG image
- **WHEN** the documented steps are followed (delete the existing `Cluster`, deploy the new manifest, run the SPIRE manifests that seed controller resources, and wait for pods to reconcile)
- **THEN** SPIRE reconnects to Postgres on the fresh database, the controller re-registers workloads, and agents can request new SVIDs without relying on an etcd backup.

