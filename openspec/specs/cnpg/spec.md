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
The system MUST automatically refresh the `otel_trace_summaries` materialized view at regular intervals using the Oban job scheduler, ensuring dashboard queries see recent trace data without manual intervention. Refresh scheduling MUST use Oban peer leader election so multi-node deployments do not enqueue duplicate refresh jobs.

#### Scenario: Oban refresh job runs without pg_cron
- **GIVEN** a CNPG cluster without the pg_cron extension installed
- **WHEN** the Oban refresh worker runs in web-ng
- **THEN** `SELECT count(*) FROM otel_trace_summaries;` returns a non-zero count after the job completes.

#### Scenario: MV refresh completes without blocking reads
- **GIVEN** the Oban refresh worker is running
- **WHEN** a query `SELECT * FROM otel_trace_summaries LIMIT 10;` is executed during refresh
- **THEN** the query returns results without waiting for the refresh to complete.

#### Scenario: Refresh cadence aligns with 2-minute schedule
- **GIVEN** web-ng is running with the default Oban cron schedule
- **WHEN** 5 minutes elapse
- **THEN** at least two refresh jobs are recorded in `oban_jobs` with worker `ServiceRadar.Jobs.RefreshTraceSummariesWorker`.

#### Scenario: Multi-node cron scheduling does not duplicate refresh jobs
- **GIVEN** web-ng and core nodes are running against the same CNPG cluster
- **WHEN** the Oban cron leader schedules refresh jobs for 5 minutes
- **THEN** the number of refresh jobs recorded in `oban_jobs` matches the expected cadence without duplicates.

### Requirement: CNPG image uses stable TimescaleDB release
The CNPG Postgres image MUST be built with stable TimescaleDB releases, not development versions, to ensure retention policy creation and other TimescaleDB features work reliably during fresh database initialization.

#### Scenario: TimescaleDB version matches stable release
- **GIVEN** a fresh cnpg container started from `ghcr.io/carverauto/serviceradar-cnpg:<version>`
- **WHEN** `SELECT extversion FROM pg_extension WHERE extname = 'timescaledb';` runs
- **THEN** the version returned is a stable release (e.g., `2.24.0`) without `-dev` suffix.

#### Scenario: Retention policies created without crashes
- **GIVEN** a fresh CNPG database with TimescaleDB extension enabled
- **WHEN** serviceradar-core runs migrations that call `add_retention_policy()` on hypertables
- **THEN** all retention policies are created successfully without postgres crashes or assertion failures.

#### Scenario: Fresh docker-compose deployment succeeds
- **GIVEN** a clean environment with `docker compose down -v` removing all volumes
- **WHEN** `docker compose up -d` starts the stack
- **THEN** cnpg becomes healthy, core completes all migrations, and all services reach healthy state.

### Requirement: CNPG build uses native TimescaleDB version
The CNPG image build process MUST NOT override TimescaleDB's native `version.config` file, ensuring the compiled extension version matches the source code version.

#### Scenario: No version.config override in build
- **GIVEN** the `timescaledb_extension_layer` genrule in `docker/images/BUILD.bazel`
- **WHEN** the build runs
- **THEN** the TimescaleDB source's original `version.config` is preserved without modification.

#### Scenario: Extension version matches source
- **GIVEN** MODULE.bazel specifies `timescaledb-2.24.0` as the source archive
- **WHEN** the cnpg image is built and deployed
- **THEN** `SELECT extversion FROM pg_extension WHERE extname = 'timescaledb';` returns `2.24.0`.

### Requirement: Logs severity continuous aggregate
The system SHALL create a TimescaleDB continuous aggregate (`logs_severity_stats_5m`) with 5-minute buckets that pre-computes log severity counts from the `logs` hypertable so dashboard stats cards can query rollups instead of scanning raw data.

#### Scenario: CAGG exists after migration
- **GIVEN** a CNPG cluster where the observability rollup stats migration has been applied
- **WHEN** an operator queries `timescaledb_information.continuous_aggregates`
- **THEN** a continuous aggregate named `logs_severity_stats_5m` exists with columns for bucket, service_name, total_count, fatal_count, error_count, warning_count, info_count, and debug_count.

#### Scenario: Severity normalization handles case variations
- **GIVEN** logs with `severity_text` values of `ERROR`, `Error`, and `error`
- **WHEN** the CAGG aggregates these logs
- **THEN** all three are counted in the `error_count` column.

#### Scenario: Severity normalization handles synonyms
- **GIVEN** logs with `severity_text` values of `warn` and `warning`
- **WHEN** the CAGG aggregates these logs
- **THEN** both are counted in the `warning_count` column.

### Requirement: Traces summary continuous aggregate
The system SHALL create a TimescaleDB continuous aggregate (`traces_stats_5m`) with 5-minute buckets that pre-computes trace statistics from root spans in the `otel_traces` hypertable.

#### Scenario: CAGG filters to root spans only
- **GIVEN** traces with multiple spans per trace
- **WHEN** the CAGG aggregates the data
- **THEN** only spans with `parent_span_id IS NULL` or empty are counted in `total_count`.

#### Scenario: CAGG computes duration percentiles
- **GIVEN** the `traces_stats_5m` CAGG exists
- **WHEN** data is aggregated
- **THEN** the CAGG includes `avg_duration_ms` and `p95_duration_ms` columns computed from span duration.

### Requirement: Services availability continuous aggregate
The system SHALL create a TimescaleDB continuous aggregate (`services_availability_5m`) with 5-minute buckets that pre-computes service availability counts from the `services` hypertable.

#### Scenario: CAGG counts unique service instances
- **GIVEN** multiple status reports for the same service within a bucket
- **WHEN** the CAGG aggregates the data
- **THEN** unique services are identified by (poller_id, agent_id, service_name) and counted once per availability state.

#### Scenario: CAGG groups by service type
- **GIVEN** services of different types (http, grpc, tcp, etc.)
- **WHEN** the CAGG aggregates the data
- **THEN** availability counts are broken down by `service_type`.

### Requirement: Continuous aggregate refresh policies
The system SHALL attach refresh policies to each observability CAGG that run every 5 minutes with appropriate offsets to handle late-arriving data.

#### Scenario: Refresh jobs exist and run regularly
- **GIVEN** the observability CAGGs are installed
- **WHEN** an operator queries `timescaledb_information.jobs`
- **THEN** each CAGG has a refresh job configured with 5-minute schedule interval.

#### Scenario: Refresh handles late-arriving data
- **GIVEN** a refresh policy with 1-hour end offset
- **WHEN** data arrives up to 1 hour late
- **THEN** subsequent refresh cycles include the late data in the appropriate buckets.

