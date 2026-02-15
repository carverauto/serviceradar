## MODIFIED Requirements
### Requirement: Mapper topology ingestion and graph projection
The system SHALL ingest mapper-discovered interfaces and topology links into CNPG and project them into an Apache AGE graph that models device and interface relationships with deterministic neighbor identity resolution.

#### Scenario: Interface ingestion
- **GIVEN** mapper discovery results include interfaces
- **WHEN** the results are ingested
- **THEN** interface records SHALL be persisted in CNPG with canonical device and interface identifiers

#### Scenario: Topology graph projection
- **GIVEN** mapper discovery results include topology links
- **WHEN** the results are ingested
- **THEN** the AGE graph SHALL upsert nodes and edges representing device-to-device connectivity derived from interface evidence
- **AND** repeated ingestion SHALL be idempotent (no duplicate effective links)

#### Scenario: Multi-interface seed normalization
- **GIVEN** a seed router has multiple interface IPs (for example `192.168.1.1` and `192.168.2.1` for farm01)
- **WHEN** discovery runs from any of those seed addresses
- **THEN** observations SHALL resolve to the same canonical device identity
- **AND** topology projection SHALL not fragment that router into multiple logical roots

## ADDED Requirements
### Requirement: Mapper neighbor identity completeness
Mapper discovery MUST emit canonical neighbor identity fields sufficient to resolve neighbors to device records or unresolved evidence records.

#### Scenario: Neighbor management identity present
- **GIVEN** LLDP/CDP/SNMP evidence includes a management address for a neighbor
- **WHEN** mapper publishes topology results
- **THEN** the payload SHALL include neighbor management IP in a canonical identity object
- **AND** the ingestor SHALL attempt canonical device resolution using that identity in the same ingestion transaction

#### Scenario: Fallback identity when management IP is unavailable
- **GIVEN** neighbor management IP is unavailable
- **WHEN** mapper publishes topology results
- **THEN** the payload SHALL include fallback identifiers (chassis ID, port ID, and available MAC/ARP evidence)
- **AND** ingestion SHALL persist unresolved evidence for later reconciliation instead of dropping it

### Requirement: Recursive discovery coverage from seed routers
Mapper discovery MUST expand coverage from configured seeds into discovered routed and L2-neighbor domains with bounded recursion.

#### Scenario: Routed downstream switch discovered from seed
- **GIVEN** seed routers include farm01 and tonka01
- **WHEN** discovery runs
- **THEN** the mapper SHALL discover reachable downstream infrastructure devices (including `192.168.10.154` behind tonka01) within configured recursion bounds

#### Scenario: Indirect endpoint evidence captured
- **GIVEN** a managed switch reports ARP/CAM/bridge evidence for downstream clients
- **WHEN** discovery runs
- **THEN** downstream endpoint observations (for example `192.168.10.96`) SHALL be emitted as topology/inventory evidence with confidence and timestamp metadata

### Requirement: Synthetic topology replay validation
The system MUST provide deterministic synthetic topology fixtures and replay tests for mapper ingestion and graph projection.

#### Scenario: Farm01 fixture produces expected adjacency
- **GIVEN** a synthetic fixture representing the expected farm01/tonka01 topology
- **WHEN** fixture data is replayed through mapper ingestion and AGE projection
- **THEN** expected device adjacencies SHALL be present in the graph output
- **AND** missing required edges SHALL fail the test

#### Scenario: Quality threshold enforcement in replay
- **GIVEN** synthetic topology replay results
- **WHEN** quality checks are evaluated
- **THEN** tests SHALL enforce thresholds for neighbor identity completeness and projected edge coverage
