## MODIFIED Requirements

### Requirement: Mapper topology ingestion and graph projection
The system SHALL ingest mapper-discovered interfaces and topology links into CNPG and project them into the Dgraph topology graph that models device/interface relationships.

#### Scenario: Interface ingestion
- **GIVEN** mapper discovery results include interfaces
- **WHEN** the results are ingested
- **THEN** interface records SHALL be persisted in CNPG with device and interface identifiers

#### Scenario: Topology graph projection
- **GIVEN** mapper discovery results include topology links
- **WHEN** the results are ingested
- **THEN** Dgraph SHALL upsert nodes and edges representing device-to-device connectivity
- **AND** repeated ingestion SHALL be idempotent (no duplicate edges)

#### Scenario: Confidence-gated topology projection
- **GIVEN** mapper produces topology link candidates with confidence labels (`high`, `medium`, `low`)
- **WHEN** the ingestor projects links to the graph
- **THEN** only `high` and `medium` links SHALL be projected by default
- **AND** `low` confidence links SHALL remain as non-projected evidence

#### Scenario: Config-declared topology uses the same projection
- **GIVEN** parsed network-config interface facts for a device
- **WHEN** the config projector runs
- **THEN** Prefix and Interface updates land in the same Dgraph topology graph as mapper links
- **AND** `topo.ingestor` is `network_config_v1`
- **AND** repeated projection SHALL be idempotent
