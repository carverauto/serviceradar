## MODIFIED Requirements
### Requirement: Mapper topology ingestion and graph projection
The system SHALL ingest mapper topology observations as typed evidence, reconcile them to canonical device identity, and project canonical device-to-device adjacency into Apache AGE.

#### Scenario: Evidence-first ingestion
- **GIVEN** mapper discovery results include topology observations
- **WHEN** the results are ingested
- **THEN** raw observations SHALL be persisted as evidence records before canonical edge projection
- **AND** canonical edge projection SHALL be idempotent for repeated observations

## ADDED Requirements
### Requirement: Versioned topology observation contract
Mapper discovery MUST emit topology observations in a versioned, typed contract that tolerates upstream API shape drift without silent semantic loss.

#### Scenario: Unknown controller fields are preserved diagnostically
- **GIVEN** a controller payload includes previously unseen topology keys
- **WHEN** mapper parses the payload
- **THEN** known fields SHALL populate typed observation fields
- **AND** unknown fields SHALL be captured in diagnostics/metadata for analysis
- **AND** ingestion SHALL continue unless required fields are missing

### Requirement: SNMP trunk and flood suppression
Mapper discovery MUST suppress direct-link generation from high-fanout SNMP bridge/FDB evidence that indicates trunk or flood behavior.

#### Scenario: Trunk ifIndex does not create endpoint fanout links
- **GIVEN** an SNMP ifIndex observes MAC entries above the configured trunk threshold
- **WHEN** topology observations are generated
- **THEN** the mapper SHALL mark that ifIndex as trunk/flood
- **AND** SHALL NOT emit direct `SNMP-L2` endpoint links for each observed MAC on that ifIndex

### Requirement: Debuggable discovery evidence bundle
The system MUST provide a per-job debug bundle containing mapper evidence and parse diagnostics sufficient to reproduce topology reconciliation outcomes.

#### Scenario: Operator exports job evidence bundle
- **GIVEN** a discovery job run completes
- **WHEN** an operator requests debug export for that run
- **THEN** the bundle SHALL include device observations, interface observations, topology observations, and parser diagnostics
- **AND** identifiers in the bundle SHALL match persisted evidence IDs
