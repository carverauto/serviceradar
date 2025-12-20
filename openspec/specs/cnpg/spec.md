# cnpg Specification

## Purpose
TBD - created by archiving change add-cnpg-timescale-age. Update Purpose after archive.
## Requirements
### Requirement: CNPG Postgres image ships TimescaleDB, Apache AGE, and pg_trgm
ServiceRadar MUST publish a CNPG-compatible Postgres image that bundles the TimescaleDB, Apache AGE, and pg_trgm extensions so clusters can enable text search optimization without manual package installs.

#### Scenario: pg_trgm extension loads successfully
- **GIVEN** the custom image tag `ghcr.io/carverauto/serviceradar-cnpg:<version>`
- **WHEN** a pod starts from that image and `psql` runs `CREATE EXTENSION IF NOT EXISTS pg_trgm;`
- **THEN** the command succeeds without downloading RPM/DEB packages at runtime.

#### Scenario: Trigram indexes can be created on text columns
- **GIVEN** a running CNPG cluster with the pg_trgm extension enabled
- **WHEN** `CREATE INDEX CONCURRENTLY idx_test_trgm ON unified_devices USING gin (hostname gin_trgm_ops);` runs
- **THEN** the index is created successfully and appears in `\di` output.

#### Scenario: ILIKE queries use trigram indexes
- **GIVEN** a GIN trigram index on `unified_devices.hostname`
- **WHEN** `EXPLAIN ANALYZE SELECT * FROM unified_devices WHERE hostname ILIKE '%server%';` runs
- **THEN** the query plan shows a Bitmap Index Scan on the trigram index instead of a sequential scan.

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

### Requirement: CNPG migrations enable pg_trgm and create trigram indexes
The CNPG migration set MUST include a migration that enables the pg_trgm extension and creates GIN trigram indexes on frequently searched text columns to optimize ILIKE query performance.

#### Scenario: Migration enables pg_trgm extension
- **GIVEN** the migration file `00000000000016_pg_trgm_extension.up.sql` exists in `pkg/db/cnpg/migrations/`
- **WHEN** the migration runs against a CNPG cluster
- **THEN** `SELECT extname FROM pg_extension WHERE extname = 'pg_trgm';` returns one row.

#### Scenario: Migration creates hostname trigram index
- **GIVEN** the pg_trgm extension is enabled
- **WHEN** the migration creates the index `idx_unified_devices_hostname_trgm`
- **THEN** the index exists and uses the `gin_trgm_ops` operator class.

#### Scenario: Migration creates ip trigram index
- **GIVEN** the pg_trgm extension is enabled
- **WHEN** the migration creates the index `idx_unified_devices_ip_trgm`
- **THEN** the index exists and uses the `gin_trgm_ops` operator class.

#### Scenario: Down migration removes extension cleanly
- **GIVEN** the pg_trgm extension and indexes are installed
- **WHEN** `00000000000016_pg_trgm_extension.down.sql` runs
- **THEN** the trigram indexes are dropped and the extension is removed without errors.

### Requirement: CNPG provides pre-computed trace summaries via materialized view

The CNPG database MUST maintain a materialized view `otel_trace_summaries` that pre-aggregates span data by trace_id, enabling fast trace listing queries without on-the-fly aggregation.

#### Scenario: Materialized view exists after migration

- **GIVEN** the migration `00000000000007_trace_summaries_mv.up.sql` in `pkg/db/cnpg/migrations/`
- **WHEN** the migration runs against a CNPG cluster with existing trace data
- **THEN** `SELECT count(*) FROM otel_trace_summaries;` returns a non-zero count matching the number of unique trace_ids in the last 7 days.

#### Scenario: Materialized view has required columns

- **GIVEN** the `otel_trace_summaries` materialized view exists
- **WHEN** `\d otel_trace_summaries` is run
- **THEN** the view contains columns: `trace_id`, `timestamp`, `root_span_id`, `root_span_name`, `root_service_name`, `root_span_kind`, `start_time_unix_nano`, `end_time_unix_nano`, `duration_ms`, `status_code`, `status_message`, `service_set`, `span_count`, `error_count`.

#### Scenario: Materialized view has unique index for concurrent refresh

- **GIVEN** the `otel_trace_summaries` materialized view exists
- **WHEN** `\di idx_trace_summaries_trace_id` is run
- **THEN** a unique index on `trace_id` is shown, enabling `REFRESH MATERIALIZED VIEW CONCURRENTLY`.

#### Scenario: Materialized view has timestamp index for time-range queries

- **GIVEN** the `otel_trace_summaries` materialized view exists
- **WHEN** `EXPLAIN ANALYZE SELECT * FROM otel_trace_summaries WHERE timestamp > NOW() - INTERVAL '1 hour' ORDER BY timestamp DESC LIMIT 100;` runs
- **THEN** the query plan shows an Index Scan on `idx_trace_summaries_timestamp` instead of a sequential scan.

#### Scenario: Materialized view has service index for filtered queries

- **GIVEN** the `otel_trace_summaries` materialized view exists
- **WHEN** `EXPLAIN ANALYZE SELECT * FROM otel_trace_summaries WHERE root_service_name = 'my-service' ORDER BY timestamp DESC LIMIT 100;` runs
- **THEN** the query plan shows an Index Scan on `idx_trace_summaries_service_timestamp`.

### Requirement: Trace summaries materialized view is refreshed periodically

The CNPG database MUST automatically refresh the `otel_trace_summaries` materialized view at regular intervals using pg_cron, ensuring dashboard queries see recent trace data without manual intervention.

#### Scenario: pg_cron job exists for MV refresh

- **GIVEN** the pg_cron extension is available in the CNPG cluster
- **WHEN** `SELECT * FROM cron.job WHERE command LIKE '%otel_trace_summaries%';` runs
- **THEN** a job is returned with schedule `*/2 * * * *` (every 2 minutes) that executes `REFRESH MATERIALIZED VIEW CONCURRENTLY otel_trace_summaries`.

#### Scenario: MV refresh completes without blocking reads

- **GIVEN** the pg_cron refresh job is running
- **WHEN** a query `SELECT * FROM otel_trace_summaries LIMIT 10;` is executed during refresh
- **THEN** the query returns results without waiting for the refresh to complete.

#### Scenario: MV refresh handles missing pg_cron gracefully

- **GIVEN** a CNPG cluster without the pg_cron extension installed
- **WHEN** the migration runs
- **THEN** the materialized view is created but no cron job is scheduled, and a notice is logged indicating manual refresh is required.

