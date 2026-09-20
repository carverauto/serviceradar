## MODIFIED Requirements

### Requirement: Mapper topology ingestion and graph projection
The system SHALL ingest mapper-discovered interfaces and topology links into CNPG and project them into the configured graph backend (Apache AGE, Dgraph, or both during dual-write) that models device/interface relationships.

#### Scenario: Interface ingestion
- **GIVEN** mapper discovery results include interfaces
- **WHEN** the results are ingested
- **THEN** interface records SHALL be persisted in CNPG with device and interface identifiers

#### Scenario: Topology graph projection
- **GIVEN** mapper discovery results include topology links
- **WHEN** the results are ingested
- **THEN** the configured graph backend SHALL upsert nodes and edges representing device-to-device connectivity
- **AND** repeated ingestion SHALL be idempotent (no duplicate edges)
- **AND** when `GRAPH_BACKEND` is `dual` or `dgraph`, Dgraph SHALL receive the projection

#### Scenario: Confidence-gated topology projection
- **GIVEN** mapper produces topology link candidates with confidence labels (`high`, `medium`, `low`)
- **WHEN** the ingestor projects links to the graph backend
- **THEN** only `high` and `medium` links SHALL be projected by default
- **AND** `low` confidence links SHALL remain as non-projected evidence

#### Scenario: Config-declared topology uses the same projection
- **GIVEN** parsed network-config interface facts for a device
- **WHEN** the config projector runs
- **THEN** Prefix and Interface updates land on the same graph backend as mapper links
- **AND** `topo.ingestor` is `network_config_v1`
- **AND** repeated projection SHALL be idempotent
