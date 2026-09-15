## ADDED Requirements

### Requirement: Analytics query-head image stays separate from the primary image
The project SHALL keep publishing a dedicated analytics PostgreSQL image (`serviceradar-cnpg-analytics`): PostgreSQL 18 with pg_duckdb, without TimescaleDB, Apache AGE, or PostGIS. The primary CNPG image's extension set and shared_preload_libraries SHALL NOT gain pg_duckdb. Every analytics-image digest bump SHALL be gated by a boot-smoke test (instance start, `CREATE EXTENSION pg_duckdb`, a Parquet round-trip).

#### Scenario: Primary image unaffected
- **WHEN** the analytics store is introduced or a table is flipped to pg_duckdb
- **THEN** the primary CNPG image and its pinned digests are unchanged

#### Scenario: Broken analytics image cannot ship
- **WHEN** an analytics-image build fails the boot-smoke test
- **THEN** the digest pin cannot be bumped

### Requirement: Analytics query head is rendered only for the pg_duckdb driver
The Helm chart SHALL render the analytics-head CNPG cluster when `analyticsStore.driver` is `pg_duckdb`, or when `analyticsStore.headEnabled` is true while the driver remains `timescale` (idle soak: no table flip). The rendered head SHALL apply a bounded DuckDB posture: execution gated to a dedicated role, per-connection memory and thread caps, spill on an `emptyDir` with a size cap, community/auto-installed extensions disabled, and LocalFileSystem disabled unless the filesystem storage backend is selected.

#### Scenario: Timescale driver
- **WHEN** `analyticsStore.driver` is `timescale` or unset
- **AND** `analyticsStore.headEnabled` is not true
- **THEN** no analytics-head Cluster, Service, or spill volume is rendered

#### Scenario: Idle soak
- **WHEN** `analyticsStore.headEnabled` is true and `analyticsStore.driver` is `timescale`
- **THEN** the analytics-head Cluster is rendered
- **AND** EventWriter keeps writing hypertables

#### Scenario: pg_duckdb driver posture
- **WHEN** `analyticsStore.driver` is `pg_duckdb`
- **THEN** the rendered cluster sets `duckdb.max_memory`, `duckdb.threads`, and `temp_directory` on an `emptyDir`
- **AND** resource requests are derived from pool size × per-connection memory
