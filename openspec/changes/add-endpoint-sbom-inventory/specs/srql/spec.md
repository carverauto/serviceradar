## ADDED Requirements

### Requirement: SRQL Exposes Endpoint Package Current State
SRQL SHALL expose endpoint software inventory current state through package, device/package, PURL, CPE, freshness, and scan provenance fields backed by indexed CNPG current-state tables.

#### Scenario: Query devices by canonical PURL
- **GIVEN** endpoint inventory current-state rows exist with canonical PURL values
- **WHEN** a client queries devices or endpoint packages by canonical PURL
- **THEN** SRQL SHALL use the canonical PURL index
- **AND** it SHALL return matching device UIDs and package identities without traversing AGE

#### Scenario: Query devices by CPE
- **GIVEN** endpoint inventory current-state rows exist with CPE arrays
- **WHEN** a client filters by CPE
- **THEN** SRQL SHALL use the GIN index on the CPE column
- **AND** it SHALL avoid a sequential scan of current package rows

#### Scenario: Device package relation is queryable
- **GIVEN** a device has current endpoint inventory
- **WHEN** the causal engine or UI queries `Device HAS_PACKAGE`
- **THEN** SRQL SHALL resolve the relation from CNPG current-state package rows
- **AND** it SHALL NOT require a package subgraph

### Requirement: SRQL Endpoint Inventory Rollups Use Maintained Aggregates
SRQL SHALL answer endpoint inventory fleet rollups from maintained current-count tables, standing-question result aggregates, or TimescaleDB continuous aggregates, not ad hoc aggregate scans over live current-state package rows.

#### Scenario: Current count query uses maintained count table
- **GIVEN** a current-count table has been maintained from package diff events
- **WHEN** a client asks how many devices currently run a package coordinate
- **THEN** SRQL SHALL read from the maintained current-count table
- **AND** it SHALL NOT perform an ad hoc `GROUP BY` over all current package rows

#### Scenario: Historical count query uses continuous aggregate
- **GIVEN** endpoint inventory history continuous aggregates exist
- **WHEN** a client asks for package host counts over time
- **THEN** SRQL SHALL route the query to the appropriate continuous aggregate
- **AND** it SHALL apply time filters to aggregate buckets

#### Scenario: Missing aggregate returns bounded error
- **GIVEN** a requested endpoint inventory rollup aggregate is unavailable
- **WHEN** SRQL cannot route to a maintained count table or continuous aggregate
- **THEN** SRQL SHALL return a bounded unsupported-rollup error
- **AND** it SHALL NOT fall back to a full current-table aggregate scan
