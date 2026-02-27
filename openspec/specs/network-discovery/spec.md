# network-discovery Specification

## Purpose
TBD - created by archiving change merge-mapper-into-agent. Update Purpose after archive.
## Requirements
### Requirement: Mapper discovery job management UI
The system SHALL provide a Settings → Networks → Discovery UI for managing mapper discovery jobs, including job schedules, seed targets, and execution scope.

#### Scenario: Admin creates a discovery job
- **GIVEN** an authenticated admin user
- **WHEN** they create a discovery job with:
  - a name
  - a schedule interval
  - seed hosts (IP/CIDR/hostname)
  - a discovery mode (SNMP or API)
  - an assigned agent or partition
- **THEN** the job SHALL be persisted and appear in the discovery jobs list

#### Scenario: Admin edits or disables a discovery job
- **GIVEN** an existing discovery job
- **WHEN** the admin edits seeds or schedule, or disables the job
- **THEN** the updated job configuration SHALL be persisted
- **AND** the agent config output SHALL reflect the change on next poll

#### Scenario: Discovery tab visibility
- **GIVEN** an authenticated admin user
- **WHEN** they navigate to Settings → Networks
- **THEN** a Discovery tab SHALL be present alongside existing network settings
- **AND** it SHALL list all mapper discovery jobs for the tenant

### Requirement: Secure credential storage for discovery
Discovery credentials (SNMP and API) MUST be stored using AshCloak encryption in CNPG and MUST be redacted in UI-facing responses.

#### Scenario: Save SNMP credentials
- **GIVEN** an admin configures SNMP discovery for a job
- **WHEN** the job is saved
- **THEN** SNMP credentials SHALL be sourced from SNMP profiles or per-device overrides (not stored on the job)
- **AND** any stored credentials (profile/device) SHALL be encrypted at rest via AshCloak
- **AND** API responses to the UI SHALL redact sensitive fields

### Requirement: Ubiquiti API discovery settings
The system SHALL support Ubiquiti discovery settings as part of mapper discovery jobs.

#### Scenario: Configure Ubiquiti controller
- **GIVEN** an admin configures a discovery job in API mode
- **WHEN** they add a Ubiquiti controller with URL, site, and credentials
- **THEN** the settings SHALL be persisted with encrypted credentials
- **AND** the mapper job config SHALL include the Ubiquiti controller definition

### Requirement: Discovery job definition schema
Discovery jobs SHALL capture the minimum fields required for mapper execution, including schedule, seeds, and credentials.

#### Scenario: Job schema completeness
- **GIVEN** a mapper discovery job
- **THEN** it includes:
  - `name`
  - `enabled`
  - `interval`
  - `seeds`
  - `discovery_mode` (SNMP or API)
  - `assignment` (agent or partition)
- **AND** SNMP credentials SHALL NOT be stored on the job record

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

### Requirement: Mapper interface count accuracy
Mapper interface results MUST report the count of unique interfaces after applying canonicalization and de-duplication rules.

#### Scenario: De-duplicated interface count in results
- **GIVEN** mapper discovery emits duplicate interface updates for the same device/interface key
- **WHEN** the agent streams mapper interface results to the gateway
- **THEN** the reported interface count SHALL equal the number of unique interfaces in the payload
- **AND** duplicate interface updates SHALL not inflate the count

### Requirement: Mapper interface de-duplication and merging
Mapper discovery MUST consolidate interface updates to a unique interface key before publishing results, merging attributes from multiple discovery sources (SNMP/API) into a single interface record.

#### Scenario: Duplicate interface from SNMP and API
- **GIVEN** the same device/interface is discovered by both SNMP and API in a single job
- **WHEN** mapper interface results are published
- **THEN** the mapper SHALL emit a single interface record per unique interface key
- **AND** the record SHALL include merged attributes from both sources

#### Scenario: Repeated discovery on the same target
- **GIVEN** a job scans the same device via multiple seed targets
- **WHEN** mapper interface results are published
- **THEN** duplicate interface updates SHALL be coalesced
- **AND** interface counts SHALL reflect unique interfaces only

### Requirement: Discovery credential resolution via profiles
Mapper discovery MUST resolve SNMP credentials via SNMP profiles and per-device overrides using the shared credential resolution rules.

#### Scenario: Discovery uses profile credentials
- **GIVEN** a device matched by an SNMP profile target_query
- **WHEN** a mapper discovery job runs against that device
- **THEN** the job SHALL use the profile credentials for SNMP access

#### Scenario: Discovery uses device overrides
- **GIVEN** a device with a per-device SNMP credential override
- **WHEN** a mapper discovery job runs against that device
- **THEN** the device override SHALL take precedence over profile credentials

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

