## ADDED Requirements

### Requirement: Discovery Observations Are Non-Canonical By Default
The network discovery pipeline SHALL treat mapper interface and neighbor observations as non-canonical identity evidence unless explicitly promoted by DIRE policy.

#### Scenario: Neighbor discovery does not directly create canonical identity links
- **GIVEN** mapper receives LLDP/CDP neighbor observations for an unresolved host
- **WHEN** discovery ingestion runs
- **THEN** observations SHALL be persisted for topology/evidence use
- **AND** canonical identity SHALL NOT be asserted solely from those observations

## MODIFIED Requirements

### Requirement: Mapper topology ingestion and graph projection
The system SHALL ingest mapper-discovered interfaces and topology links into CNPG and project them into an Apache AGE graph that models device/interface relationships, while keeping discovery-time identity evidence decoupled from canonical identity assignment.

#### Scenario: Interface ingestion preserves topology without forcing canonical identity
- **GIVEN** mapper discovery results include interfaces
- **WHEN** the results are ingested
- **THEN** interface records SHALL be persisted in CNPG with current best-known device linkage
- **AND** identity evidence from those records SHALL remain non-canonical unless promoted by DIRE policy

#### Scenario: Topology graph projection remains idempotent under identity evidence updates
- **GIVEN** mapper discovery results include topology links and repeated evidence updates
- **WHEN** the results are ingested repeatedly
- **THEN** the AGE graph SHALL remain idempotent for connectivity edges
- **AND** identity evidence updates SHALL NOT create duplicate topology edges
