## MODIFIED Requirements
### Requirement: Mapper topology ingestion and graph projection
The system SHALL ingest mapper-discovered interfaces and topology links into CNPG and project them into an Apache AGE graph that models device/interface relationships.

#### Scenario: Interface ingestion
- **GIVEN** mapper discovery results include interfaces
- **WHEN** the results are ingested
- **THEN** interface records SHALL be persisted in CNPG with device and interface identifiers

#### Scenario: Topology graph projection
- **GIVEN** mapper discovery results include topology links
- **WHEN** the results are ingested
- **THEN** the AGE graph SHALL upsert nodes and edges representing device-to-device connectivity
- **AND** repeated ingestion SHALL be idempotent (no duplicate edges)

#### Scenario: Confidence-gated topology projection
- **GIVEN** mapper produces topology link candidates with confidence labels (`high`, `medium`, `low`)
- **WHEN** the ingestor projects links to AGE
- **THEN** only `high` and `medium` links SHALL be projected by default
- **AND** `low` confidence links SHALL remain as non-projected evidence

## ADDED Requirements
### Requirement: Discovery ingestion stores SNMP fingerprint metadata
The mapper results ingestor SHALL persist normalized SNMP fingerprint metadata from discovery payloads for downstream enrichment and identity logic.

#### Scenario: Fingerprint persisted with discovery result
- **GIVEN** mapper publishes a discovery payload containing `snmp_fingerprint`
- **WHEN** core ingests the payload
- **THEN** fingerprint fields SHALL be persisted and exposed to enrichment/identity processing in the same ingestion transaction
