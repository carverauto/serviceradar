## ADDED Requirements

### Requirement: Endpoint Inventory Current And History Storage
CNPG SHALL store endpoint inventory current state in regular `platform` schema tables and endpoint inventory history in TimescaleDB hypertables when TimescaleDB is available.

#### Scenario: Current-state tables are platform-scoped
- **GIVEN** endpoint inventory migrations run
- **WHEN** current scan, package, artifact, package entity, and device/package relation tables are created
- **THEN** they SHALL be created in the `platform` schema
- **AND** they SHALL not create schema objects in `public`

#### Scenario: History hypertables use TimescaleDB policy hooks
- **GIVEN** TimescaleDB is available
- **WHEN** endpoint inventory history tables are migrated
- **THEN** changed scans and package add/remove/version-change events SHALL be converted to hypertables via the existing `maybe_create_hypertable` convention
- **AND** compression and retention policies SHALL be attached

#### Scenario: TimescaleDB absent degrades to plain tables
- **GIVEN** TimescaleDB is unavailable in a non-production development database
- **WHEN** endpoint inventory migrations run
- **THEN** history tables SHALL remain usable plain tables
- **AND** migration SHALL not fail solely because hypertable conversion is unavailable

### Requirement: Endpoint Inventory Aggregates Avoid Current Table Group Scans
CNPG SHALL maintain endpoint inventory count data so fleet rollups can be served without ad hoc aggregate scans over current package rows.

#### Scenario: Current count table updated from package diffs
- **GIVEN** a package diff event is computed at ingest
- **WHEN** current package state changes for a device
- **THEN** the maintained current-count table SHALL be incremented or decremented for affected package coordinates
- **AND** unchanged scans SHALL NOT touch current counts

#### Scenario: Historical aggregate created
- **GIVEN** endpoint inventory package event history exists
- **WHEN** migrations install fleet rollups
- **THEN** TimescaleDB continuous aggregates SHALL be created for package/version/ecosystem/CPE host counts over time
- **AND** refresh and retention policy behavior SHALL be documented in the migration or owning worker

### Requirement: Endpoint Inventory History Is Not CDC-Replayed
Endpoint inventory history hypertables SHALL be queried on demand and SHALL NOT be included in CDC/logical-replication allowlists.

#### Scenario: History excluded from CDC allowlist
- **GIVEN** CDC/logical-replication allowlists are generated or reviewed
- **WHEN** endpoint inventory history hypertables exist
- **THEN** those hypertables SHALL be excluded
- **AND** only current-state tables MAY be CDC candidates
