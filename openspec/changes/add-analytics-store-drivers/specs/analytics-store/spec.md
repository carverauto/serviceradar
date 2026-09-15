## ADDED Requirements

### Requirement: Analytics-store mode is an explicit deployment choice
The system SHALL support `timescale`, `hybrid`, and `pg_duckdb` modes. Default OSS Helm and Compose installations SHALL use Timescale alone and SHALL NOT require object storage, archive credentials, or an analytics head. Hosted deployment configuration SHALL enable hybrid explicitly without changing OSS defaults. Hybrid SHALL require a named table list; unlisted tables SHALL stay on Timescale.

#### Scenario: Default OSS installation
- **WHEN** an operator installs with default values and no object-store configuration
- **THEN** EventWriter and all analytics reads use Timescale
- **AND** no analytics-head or MinIO workload is required

#### Scenario: Optional hybrid enablement
- **WHEN** an operator enables hybrid for `timeseries_metrics` with a complete archive backend
- **THEN** that table uses continuous dual writes and time-based reads
- **AND** unlisted tables retain their existing Timescale behavior

#### Scenario: Incomplete archive configuration
- **WHEN** hybrid or pg_duckdb is selected without the required head and storage configuration
- **THEN** configuration validation fails
- **AND** there is no silent fallback to another storage mode

### Requirement: EventWriter owns continuous dual writes
Collectors and agents SHALL publish through JetStream and SHALL NOT write either datastore directly. In hybrid mode, the existing EventWriter SHALL write each canonical batch to Timescale and verified Parquet, and SHALL durably commit the hot rows, source receipts, and archive publication work in one primary transaction before acknowledging consumed messages. An EventWriter-owned publisher SHALL publish fixed batches asynchronously; publication failures SHALL retain durable payloads for retry. Continuous dual writing SHALL be optional and SHALL NOT create a second telemetry consumer. Partial failure SHALL retain retryability and logical row identity.

#### Scenario: Successful hybrid batch
- **WHEN** EventWriter consumes a batch for a hybrid table
- **THEN** the hot hypertable and durable archive outbox receive that batch atomically
- **AND** the messages are acknowledged after commit
- **AND** the publisher makes one verified archive object visible for each fixed batch

#### Scenario: Archive write fails after hot commit
- **WHEN** Timescale accepts a batch but archive publication fails
- **THEN** the hot copy remains available
- **AND** the durable batch remains pending for publication retry
- **AND** the archive buffer limit rejects new ingest transactions under the configured JetStream retention, retry, and terminal-delivery limits without evicting committed pending work

#### Scenario: Timescale-only default
- **WHEN** hybrid and named dual writes are disabled
- **THEN** EventWriter writes Timescale only
- **AND** no object-store request or archive connection is required

### Requirement: Recent reads use the hot copy and historical reads use the full archive
Hybrid SHALL select Timescale for a resolved query whose lower time bound is at or after `now - hotWindowDays`, with 30 days as the default. An older or unbounded lower bound SHALL select pg_duckdb for the entire query. Existing entity time defaults SHALL resolve before this decision. Store failures SHALL be returned without silently changing the selected store.

#### Scenario: Recent dashboard query
- **WHEN** a hybrid metrics query requests the last hour
- **THEN** it executes on Timescale without listing archive files or acquiring an analytics connection

#### Scenario: Query spans the cutoff
- **WHEN** a hybrid query includes timestamps on both sides of the hot cutoff
- **THEN** the whole query executes against the complete Parquet copy
- **AND** aggregation, rate calculation, ordering, and pagination occur once

#### Scenario: Exact boundary
- **WHEN** a query's lower bound equals the resolved hot cutoff
- **THEN** it uses Timescale

### Requirement: Archive publication uses verified manifest files
The archive SHALL use S3-compatible storage or a persistent filesystem with a dedicated pg_duckdb head. EventWriter SHALL stage, verify, then publish Parquet under `analytics/v1/<table>/date=YYYY-MM-DD/`. Interactive readers SHALL use concrete published keys from the primary's manifest and SHALL NOT plan a wildcard across all dates. Spill SHALL remain ephemeral and separate from persistent Parquet data.

#### Scenario: Interrupted COPY
- **WHEN** a Parquet COPY fails verification
- **THEN** its staging object is not query-visible

#### Scenario: Bounded archive read
- **WHEN** a historical query has a resolved time window
- **THEN** the primary manifest supplies overlapping published file keys
- **AND** manifest lookup failure returns an error rather than an incomplete success

### Requirement: Hybrid retention preserves the hot guarantee and archive history
Hybrid SHALL retain Timescale rows for at least the hot read window, preserve any longer configured table retention, and keep the table's CAGGs refreshing. Archive expiry SHALL be configured independently through `parquetRetentionDays`; absence SHALL mean no expiry deletion, and a finite value SHALL exceed the hot window. Pure pg_duckdb mode SHALL retain its existing table-retention behavior and SHALL not refresh the table's Timescale CAGGs.

#### Scenario: Existing shorter hot retention
- **WHEN** a hybrid table's existing retention is shorter than its hot read window
- **THEN** retention reconciliation raises it to cover that window
- **AND** rollout restores missing historical coverage before claiming the window is available

#### Scenario: Return from Parquet-only mode
- **WHEN** a table returns to hybrid and its CAGG refresh policies were removed
- **THEN** reconciliation restores those policies
- **AND** recovery refreshes the restored interval before aggregate acceptance

#### Scenario: No archive expiry specified
- **WHEN** a hybrid operator does not configure `parquetRetentionDays`
- **THEN** the pruner does not delete archive objects by the hot retention window

#### Scenario: Explicit archive expiry
- **WHEN** a published object is older than the configured archive expiry
- **THEN** its object is deleted before its manifest entry
- **AND** a failed delete retains the manifest entry

### Requirement: Archive publication is idempotent before query execution
Hybrid EventWriter SHALL persist source receipts independently of hot retention and fix archive batch contents before publication. Regrouped delivery attempts SHALL NOT create additional archive copies. A batch SHALL select one immutable published object atomically with its completion. Query execution SHALL NOT require row deduplication to compensate for transport retries.

#### Scenario: Regrouped retry
- **WHEN** a committed batch containing messages A and B is retried as B and C
- **THEN** B is recognized from its durable receipt
- **AND** only C can create new hot rows and archive publication work

#### Scenario: Lost acknowledgement after hot expiry
- **WHEN** an original source message is redelivered after its hot row has expired
- **THEN** its durable receipt prevents a second archive batch

#### Scenario: Concurrent or uncertain publication
- **WHEN** two attempts upload candidates for the same durable batch
- **THEN** only one manifest entry can become visible
- **AND** completion and payload cleanup are committed with that selection

#### Scenario: Pending archive data in a historical query
- **WHEN** a historical query overlaps pending batches
- **THEN** it waits a bounded interval for the batch IDs captured at query start
- **AND** it returns an explicit archive-not-ready error if those batches remain unpublished
- **AND** recent Timescale queries are unaffected
