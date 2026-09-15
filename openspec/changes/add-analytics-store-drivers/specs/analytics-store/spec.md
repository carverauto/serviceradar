## ADDED Requirements

### Requirement: Analytics-store driver is selected by deployment configuration
The system SHALL persist and query analytics-store tables through a single store interface whose concrete driver is selected by deployment configuration (`timescale` or `pg_duckdb`). When the driver is `timescale` or the configuration is absent, write and query behavior for those tables SHALL match current CNPG hypertable behavior. When the driver is `pg_duckdb`, the system SHALL require a complete storage backend configuration and SHALL refuse to start rather than silently write hypertables.

#### Scenario: Default OSS / farm01
- **WHEN** Helm or Compose is installed with default values
- **THEN** the analytics-store driver is `timescale`
- **AND** no analytics-head workload is rendered
- **AND** EventWriter and SRQL continue to use the primary hypertables

#### Scenario: Incomplete pg_duckdb configuration fails closed
- **WHEN** `driver` is `pg_duckdb` and the storage backend (S3 credentials/bucket or filesystem data dir) is missing
- **THEN** core does not start
- **AND** EventWriter does not fall back to hypertable inserts for configured tables

#### Scenario: Per-table flip
- **WHEN** deployment configuration lists a subset of registry tables on `pg_duckdb`
- **THEN** only those tables use the pg_duckdb driver
- **AND** unlisted registry tables remain on Timescale

### Requirement: pg_duckdb driver stores telemetry as hive-partitioned Parquet
When a table uses the pg_duckdb driver, EventWriter SHALL write that table's rows as hive-partitioned Parquet (`analytics/v1/<table>/date=YYYY-MM-DD/`) through the analytics head, and SHALL NOT insert those rows into the corresponding CNPG hypertable. Published objects SHALL be verified before they are query-visible. The analytics head SHALL be rebuildable from the published objects plus a manifest stored on the primary.

#### Scenario: Write path does not touch the hypertable
- **WHEN** `timeseries_metrics` is configured on the pg_duckdb driver
- **AND** EventWriter consumes a metrics batch from JetStream
- **THEN** a verified Parquet object appears under that table's prefix
- **AND** `platform.timeseries_metrics` on the primary does not gain those rows

#### Scenario: Truncated export is not query-visible
- **WHEN** a COPY to Parquet is interrupted
- **THEN** the incomplete object remains in staging
- **AND** readers globbing published keys do not see it

#### Scenario: Head restart
- **WHEN** the analytics-head pod is deleted and recreated
- **THEN** it rebuilds `platform.<table>` views from the manifest and storage backend
- **AND** a subsequent SRQL query on that table returns the previously published rows

### Requirement: Parquet storage backend is S3 or filesystem
The pg_duckdb driver SHALL support two storage backends selected by deployment configuration: S3-compatible object storage, and a local filesystem data directory (hostPath or a dedicated PVC). Spill files SHALL use an `emptyDir` with an explicit memory limit and SHALL NOT share the Parquet data volume. The filesystem backend SHALL NOT be an `emptyDir`.

#### Scenario: S3 backend
- **WHEN** `analyticsStore.pgDuckdb.storage` is `s3` with a bucket and credentials
- **THEN** writes and `read_parquet` use that bucket
- **AND** DuckDB LocalFileSystem access remains disabled

#### Scenario: Filesystem backend
- **WHEN** `analyticsStore.pgDuckdb.storage` is `filesystem` with a data-dir path
- **THEN** writes and reads use that directory
- **AND** LocalFileSystem is permitted only for that prefix

#### Scenario: Spill is ephemeral
- **WHEN** the analytics head is scheduled
- **THEN** `temp_directory` is an `emptyDir` with a configured size cap
- **AND** `memory_limit` / `duckdb.max_memory` is set from Helm values

### Requirement: JetStream remains the ingest bus; EventWriter remains the single writer
Collectors and agents SHALL NOT write the analytics store. Every analytics-store table SHALL have exactly one EventWriter processor persisting it after JetStream, regardless of driver. A dual-write window SHALL exist only as an explicit, named cutover flag for a table and SHALL be removed once SRQL parity for that table passes.

#### Scenario: Collector cannot bypass the store
- **WHEN** a new metric source is added
- **THEN** it publishes to JetStream
- **AND** it does not open a DuckDB, S3, or hypertable connection of its own

#### Scenario: Dual-write is opt-in and temporary
- **WHEN** a table's cutover flag is off
- **THEN** only the selected driver receives writes
- **AND** there is not a second consumer inserting the same rows into the other backend

### Requirement: Flipped tables leave Timescale CAGGs and drop Parquet by the existing retention window
When a table uses the pg_duckdb driver, the system SHALL stop Timescale continuous-aggregate refresh for that table's views, SHALL NOT install or run Timescale `drop_chunks` for that table, and SHALL delete published Parquet objects older than the table's configured retention window before removing their manifest rows. Dual-write SHALL keep Timescale CAGG refresh and Timescale retention because the hypertable is still the store. SRQL on a flipped table SHALL aggregate over Parquet rather than those CAGGs. The system SHALL NOT keep a shadow hypertable solely to feed CAGGs.

#### Scenario: Dual-write still feeds CAGGs
- **WHEN** a table is dual-written and the selected driver is still `timescale`
- **THEN** Timescale CAGG refresh policies remain installed
- **AND** Timescale retention still ages the hypertable
- **AND** Parquet prune does not run for that table

#### Scenario: Flip stops CAGG refresh
- **WHEN** `timeseries_metrics` is configured on the pg_duckdb driver
- **THEN** `remove_continuous_aggregate_policy` runs for `timeseries_metrics_hourly`, `timeseries_metrics_interface_hourly`, and `timeseries_metrics_disk_hourly`
- **AND** the views remain in the catalog for rollback
- **AND** `DataRetentionWorker` does not `drop_chunks` that hypertable

#### Scenario: Parquet prune is object-first
- **WHEN** a published object is older than the table's `SERVICERADAR_*_RETENTION_DAYS` window
- **THEN** the object is deleted from the storage backend
- **AND** the `analytics_file_manifest` row is removed only after that delete succeeds
- **AND** readers never glob `_staging/` keys

#### Scenario: Sysmon hourly CAGGs stay until those tables flip
- **WHEN** only `timeseries_metrics` is on pg_duckdb
- **THEN** `cpu_metrics_hourly`, `memory_metrics_hourly`, `disk_metrics_hourly`, and `process_metrics_hourly` keep refreshing from their Timescale hypertables
