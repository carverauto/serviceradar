## ADDED Requirements

### Requirement: Discovery Observations Are Non-Canonical By Default
The network discovery pipeline SHALL treat mapper interface and neighbor observations as non-canonical identity evidence unless explicitly promoted by DIRE policy.

#### Scenario: Neighbor discovery does not directly create canonical identity links
- **GIVEN** mapper receives LLDP/CDP neighbor observations for an unresolved host
- **WHEN** discovery ingestion runs
- **THEN** observations SHALL be persisted for topology/evidence use
- **AND** canonical identity SHALL NOT be asserted solely from those observations

### Requirement: Role-Aware Alias Promotion
The network discovery pipeline SHALL apply role-aware alias promotion so self-owned router interface IPs are retained as aliases while AP/bridge client-like interface IPs are not promoted as aliases.

#### Scenario: Router interface aliases are retained
- **GIVEN** mapper interfaces for a router share a stable management `device_ip`
- **AND** interface `ip_addresses` contain multiple configured L3 interface IPs
- **WHEN** mapper alias processing executes
- **THEN** those configured interface IPs SHALL be promoted as aliases for the router device

#### Scenario: AP client IP artifacts are not promoted as aliases
- **GIVEN** mapper interface updates for an AP/bridge include observed client IP-like values
- **WHEN** mapper alias processing executes
- **THEN** client IP-like values SHALL NOT be promoted as aliases of the AP/bridge device

### Requirement: Filtered Client IPs Become Discovery Candidates
When role-aware alias policy filters AP/bridge client IP-like interface observations, the system SHALL preserve them as endpoint discovery candidates for downstream device creation/deduplication workflows.

#### Scenario: Filtered AP client IP is emitted as candidate endpoint
- **GIVEN** an AP/bridge interface observation includes an IP value filtered from alias promotion
- **WHEN** mapper ingestion completes
- **THEN** the filtered IP observation SHALL be recorded as a discovery candidate
- **AND** it SHALL be eligible for normal device creation/reconciliation in subsequent discovery flows

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
