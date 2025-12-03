# cnpg Specification

## Purpose
TBD - created by archiving change add-cnpg-timescale-age. Update Purpose after archive.
## Requirements
### Requirement: CNPG Postgres image ships TimescaleDB, Apache AGE, and pg_trgm
ServiceRadar MUST publish a CNPG-compatible Postgres image that bundles the TimescaleDB, Apache AGE, and pg_trgm extensions so clusters can enable time-series storage, graph queries, and optimized text search without manual package installs.

#### Scenario: Extensions load successfully
- **GIVEN** the custom image tag `ghcr.io/carverauto/serviceradar-cnpg:<version>`
- **WHEN** a pod starts from that image and `psql` runs `CREATE EXTENSION IF NOT EXISTS timescaledb; CREATE EXTENSION IF NOT EXISTS age; CREATE EXTENSION IF NOT EXISTS pg_trgm;`
- **THEN** all three commands succeed without downloading RPM/DEB packages at runtime.

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

### Requirement: Trigram indexes optimize ILIKE text search queries
The CNPG migrations MUST create GIN trigram indexes on frequently searched text columns to prevent full table scans when users run case-insensitive pattern matching queries via SRQL.

#### Scenario: pg_trgm extension enabled by migration
- **GIVEN** the migration `00000000000016_pg_trgm_extension.up.sql` in `pkg/db/cnpg/migrations/`
- **WHEN** serviceradar-core runs migrations on startup
- **THEN** `SELECT extname FROM pg_extension WHERE extname = 'pg_trgm';` returns one row.

#### Scenario: GIN trigram indexes exist on unified_devices
- **GIVEN** the pg_trgm extension is enabled
- **WHEN** the migration completes
- **THEN** `\di+ idx_unified_devices_*_trgm` shows GIN indexes on `hostname` and `ip` columns using `gin_trgm_ops`.

#### Scenario: ILIKE queries use trigram indexes on large tables
- **GIVEN** a `unified_devices` table with more than 1000 rows
- **WHEN** `EXPLAIN ANALYZE SELECT * FROM unified_devices WHERE hostname ILIKE '%pattern%';` runs
- **THEN** the query plan shows a Bitmap Index Scan on `idx_unified_devices_hostname_trgm` instead of a sequential scan.

