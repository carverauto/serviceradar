## ADDED Requirements

### Requirement: NetFlow raw data retention policy
The system SHALL enforce a retention policy for raw NetFlow-derived records so storage growth remains bounded under sustained ingestion.

#### Scenario: Raw flow TTL is enforced
- **GIVEN** raw NetFlow records older than the configured TTL (default 7 days)
- **WHEN** the retention policy runs
- **THEN** those records are removed from the raw flow hypertable

### Requirement: NetFlow rollup continuous aggregates for dashboard widgets
The system SHALL provide TimescaleDB continuous aggregates for common NetFlow dashboard widgets to avoid scanning raw flow hypertables for each UI refresh.

#### Scenario: Top talkers rollup exists
- **WHEN** an operator inspects Timescale continuous aggregates
- **THEN** a NetFlow rollup aggregate exists that supports top talkers queries by time bucket

#### Scenario: Traffic over time rollup exists
- **WHEN** an operator inspects Timescale continuous aggregates
- **THEN** a NetFlow rollup aggregate exists that supports bytes/packets over time queries by bucket

### Requirement: Cached enrichment lookup storage
The system SHALL store cached enrichment results (GeoIP, ASN, rDNS) in CNPG with TTL so enrichment does not require repeated external calls and can be shared across UI nodes.

#### Scenario: Enrichment cache hit avoids repeated lookups
- **GIVEN** an IP enrichment cache entry exists and is not expired
- **WHEN** a flow query requests enrichment for that IP
- **THEN** the system uses the cached enrichment data without performing a new lookup
