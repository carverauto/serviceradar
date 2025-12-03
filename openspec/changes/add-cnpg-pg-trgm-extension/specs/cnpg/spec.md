## MODIFIED Requirements
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

## ADDED Requirements
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
