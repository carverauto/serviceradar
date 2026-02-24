## ADDED Requirements
### Requirement: Directional edge telemetry uses existing interface metrics
The system SHALL derive directional edge telemetry from existing collected interface counters (`ifIn*` / `ifOut*`) and SHALL NOT require a new collection pipeline to support God-View directionality.

#### Scenario: Existing counters available
- **GIVEN** interface directional counters are present for a discovered link endpoint
- **WHEN** God-View edge telemetry is enriched
- **THEN** directional edge rates SHALL be derived from those counters
- **AND** no additional polling source SHALL be required for that edge

### Requirement: Directional topology edge telemetry preservation
The system SHALL preserve directional traffic telemetry for canonical topology edges by carrying A→B and B→A packet/bit rates through enrichment and snapshot export.

#### Scenario: Both-sided interface telemetry available
- **GIVEN** a canonical topology edge where interface telemetry is available for both endpoint sides
- **WHEN** topology edge telemetry is enriched for God-View
- **THEN** the edge SHALL include directional fields for both A→B and B→A rates
- **AND** aggregate edge telemetry fields SHALL remain available for compatibility

#### Scenario: One-sided interface telemetry available
- **GIVEN** a canonical topology edge where telemetry is available for only one endpoint side
- **WHEN** telemetry is enriched
- **THEN** the available directional side SHALL be populated
- **AND** the missing side SHALL be explicitly empty/zero according to the edge telemetry contract
- **AND** enrichment SHALL NOT synthesize the missing direction from aggregate values

#### Scenario: Canonical dedupe retains directional telemetry
- **GIVEN** multiple mapper topology rows that collapse into one canonical edge
- **WHEN** deduplication and enrichment run
- **THEN** the resulting canonical edge SHALL retain directional rates for both sides when available
- **AND** directional telemetry SHALL NOT be dropped solely because the edge structure is undirected

#### Scenario: Canonical endpoint order does not change direction semantics
- **GIVEN** the same physical link appears with opposite endpoint ordering in upstream topology rows
- **WHEN** canonicalization and enrichment run
- **THEN** the published `*_ab` and `*_ba` values SHALL preserve consistent A→B and B→A semantics for the canonical edge
- **AND** direction assignments SHALL NOT flip due to row ordering

### Requirement: Directional edge telemetry unit consistency
Directional packet and bit rates SHALL use the same units and conversion rules as existing interface telemetry exports.

#### Scenario: Interface octet deltas convert to directional bit rates
- **GIVEN** interface octet deltas are used as the source signal
- **WHEN** directional bit rates are computed for an edge
- **THEN** values SHALL be converted to bits-per-second using the existing platform conversion logic
- **AND** reported values SHALL be consistent with interface-level throughput views for the same interval

### Requirement: Topology telemetry metric bootstrap
The system SHALL provide discovery/mapper-controlled bootstrap for topology telemetry so topology-linked interfaces receive the minimum SNMP metrics required by God-View without manual per-interface setup.

#### Scenario: Mapper auto-bootstrap enabled
- **GIVEN** mapper/discovery auto-bootstrap for topology telemetry is enabled
- **WHEN** a topology link is discovered for an interface that lacks required SNMP metric OIDs
- **THEN** the platform SHALL ensure the interface is configured to collect at least octet and packet counters (`ifIn/OutOctets`, `ifIn/OutUcastPkts`, and HC variants when supported)
- **AND** repeated reconciliation runs SHALL be idempotent

#### Scenario: Mapper auto-bootstrap disabled
- **GIVEN** mapper/discovery auto-bootstrap for topology telemetry is disabled
- **WHEN** topology links are discovered
- **THEN** the platform SHALL NOT mutate interface metric selections automatically

### Requirement: Telemetry eligibility for topology links
Topology links SHALL expose telemetry eligibility based on whether interface attribution and required metrics are present.

#### Scenario: UniFi/API link missing interface attribution
- **GIVEN** a topology link discovered from UniFi/API evidence without usable interface identifiers (`if_index`/`if_name`)
- **WHEN** edge telemetry enrichment runs
- **THEN** the link SHALL be marked telemetry-ineligible for interface-derived directional rates
- **AND** enrichment SHALL NOT invent interface mappings

### Requirement: SNMP-attributed topology evidence precedence
For telemetry-bearing canonical edges, the system SHALL prefer topology evidence with usable SNMP interface attribution (LLDP/CDP/SNMP-L2) over UniFi/API-only evidence lacking interface attribution.

#### Scenario: Canonical pair includes LLDP and UniFi/API rows
- **GIVEN** a canonical edge pair where LLDP (or CDP/SNMP-L2) evidence has valid interface attribution and UniFi/API evidence does not
- **WHEN** canonical edge selection and telemetry enrichment run
- **THEN** telemetry-bearing edge semantics SHALL be derived from the SNMP-attributed evidence
- **AND** UniFi/API-only evidence MAY remain as structural/discovery context but SHALL NOT override telemetry mapping

### Requirement: SNMP topology enrichment completeness per scan
SNMP topology discovery SHALL execute LLDP/CDP discovery and SNMP-L2 enrichment in the same scan cycle so non-LLDP neighbors remain discoverable and attributable.

#### Scenario: LLDP neighbors exist with additional non-LLDP neighbors
- **GIVEN** a device where LLDP returns at least one neighbor
- **AND** additional neighbors are only inferable via SNMP ARP+FDB evidence
- **WHEN** topology discovery runs
- **THEN** LLDP/CDP links SHALL be published
- **AND** SNMP-L2 enrichment SHALL still run in that same scan
- **AND** eligible non-LLDP neighbors SHALL also be published with SNMP-L2 attribution
