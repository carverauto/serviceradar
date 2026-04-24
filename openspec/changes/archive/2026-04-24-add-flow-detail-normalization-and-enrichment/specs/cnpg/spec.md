## ADDED Requirements

### Requirement: Flow enrichment fields SHALL be persisted at ingestion time
The ingestion pipeline SHALL normalize and persist canonical flow enrichment fields in CNPG when flow records are stored, including protocol label mapping, decoded TCP flag labels, destination service label metadata, directionality classification, and endpoint MAC vendor attribution.

#### Scenario: Protocol and TCP enrichment persisted on write
- **GIVEN** an ingested flow record with `protocol_num = 6` and `tcp_flags = 18`
- **WHEN** the record is written to CNPG
- **THEN** persisted enrichment fields include canonical protocol label `tcp`
- **AND** include decoded TCP flag labels `SYN` and `ACK`
- **AND** retain raw protocol number and raw tcp flag bitmask values

#### Scenario: Unknown mappings persist deterministic fallback
- **GIVEN** an ingested flow record with unknown protocol/service mappings
- **WHEN** the record is written to CNPG
- **THEN** persisted enrichment fields use deterministic unknown labels
- **AND** include enrichment source metadata marking those values as unknown

#### Scenario: OUI vendor enrichment persisted on write
- **GIVEN** an ingested flow record with source or destination MAC addresses
- **AND** an active IEEE OUI snapshot contains matching prefixes
- **WHEN** the record is written to CNPG
- **THEN** persisted enrichment fields include endpoint MAC vendor labels
- **AND** enrichment source is recorded as OUI dataset driven

### Requirement: Provider-hosting classification SHALL be persisted from cloud CIDR dataset
The ingestion pipeline SHALL classify flow endpoints against the active cloud-provider CIDR dataset and persist provider-hosting enrichment fields for flow detail consumption.

#### Scenario: Flow endpoint matches provider CIDR
- **GIVEN** an active provider CIDR snapshot contains a range covering a flow source IP
- **WHEN** the flow is ingested
- **THEN** the persisted flow enrichment includes provider-hosting classification and provider identity
- **AND** enrichment source is recorded as dataset-driven

#### Scenario: No provider match falls back to unknown
- **GIVEN** a flow endpoint IP does not match any active provider CIDR range
- **WHEN** the flow is ingested
- **THEN** provider-hosting classification is persisted as unknown
- **AND** ingestion continues without failure

### Requirement: CNPG SHALL store provider and OUI enrichment datasets in platform schema
CNPG SHALL store cloud-provider CIDR snapshots and IEEE OUI snapshots in platform-schema tables with active snapshot metadata so ingestion can resolve provider and MAC vendor enrichment without in-memory-only datasets.

#### Scenario: Provider and OUI snapshots persisted in platform schema
- **GIVEN** refresh jobs complete successfully
- **WHEN** snapshots are promoted
- **THEN** active provider CIDR and active OUI snapshot metadata are persisted in `platform` schema tables
- **AND** ingestion lookups read from those active snapshots
