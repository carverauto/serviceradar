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

#### Scenario: Confidence-gated topology projection
- **GIVEN** mapper produces topology link candidates with confidence labels (`high`, `medium`, `low`)
- **WHEN** the ingestor projects links to AGE
- **THEN** only `high` and `medium` links SHALL be projected by default
- **AND** `low` confidence links SHALL remain as non-projected evidence

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

### Requirement: Standalone mapper baseline runs
The system SHALL provide a standalone mapper baseline tool that runs the existing discovery engine against explicitly supplied targets or controller endpoints without requiring ingestion into CNPG.

#### Scenario: Run an SNMP baseline against explicit targets
- **GIVEN** an operator supplies one or more SNMP targets and credentials explicitly
- **WHEN** the mapper baseline tool runs
- **THEN** it SHALL execute discovery using the existing mapper/discovery library
- **AND** it SHALL emit structured devices, interfaces, topology links, and summary counts

#### Scenario: Run a controller baseline against explicit API credentials
- **GIVEN** an operator supplies a UniFi or MikroTik controller endpoint and explicit credentials
- **WHEN** the mapper baseline tool runs
- **THEN** it SHALL query the controller through the existing mapper integrations
- **AND** it SHALL emit a stable report suitable for comparison with ingested topology evidence

### Requirement: Baseline credential resolution boundary
Saved discovery controller credentials MUST only be resolved for baseline runs through ServiceRadar-managed Ash/Vault paths and MUST NOT be decrypted directly from Postgres by the standalone Go tool.

#### Scenario: Run a baseline from saved controller configuration
- **GIVEN** an operator wants to baseline a saved mapper job or controller definition
- **WHEN** the system resolves the required credentials
- **THEN** the credentials SHALL be exported through a ServiceRadar-managed Ash/Vault path
- **AND** the standalone Go tool SHALL consume the exported runtime config rather than decrypting CNPG rows directly

#### Scenario: Direct database decryption is rejected
- **GIVEN** a request to read encrypted controller credentials directly from CNPG in the standalone Go tool
- **WHEN** the baseline workflow is implemented
- **THEN** the Go tool SHALL NOT implement AshCloak or Vault decryption logic against database rows
- **AND** the supported path SHALL remain an Ash-managed export boundary or explicit operator-supplied credentials

### Requirement: Staged Discovery Pipeline Execution
The mapper discovery engine SHALL execute discovery in explicit stages with deterministic ordering and isolation between identity and topology resolution.

#### Scenario: Identity stage precedes topology stage
- **GIVEN** a discovery job is executing
- **WHEN** the pipeline transitions through stages
- **THEN** identity reconciliation SHALL complete before topology relationship resolution begins
- **AND** topology evidence SHALL not mutate identity stage decisions in the same execution pass

### Requirement: Structured Discovery Payload Contracts
The mapper SHALL emit structured discovery payload contracts and SHALL NOT rely on untyped raw payload maps for cross-service semantics.

#### Scenario: Discovery payload is contract-typed
- **GIVEN** discovery results are published
- **WHEN** downstream ingestion consumes the payload
- **THEN** identity, topology, and enrichment fields SHALL be represented in typed contract fields
- **AND** payload interpretation SHALL not depend on untyped key guessing

### Requirement: Backend-Owned GodView Edge Contract
Network discovery ingestion and reconciliation SHALL emit a canonical topology edge contract for GodView without requiring frontend topology inference.

#### Scenario: Canonical edges are emitted from backend
- **GIVEN** discovery evidence has been ingested
- **WHEN** the reconciliation/projection pipeline completes
- **THEN** backend emits canonical edges with directional interface attribution and directional telemetry
- **AND** frontend receives these canonical edges directly from backend stream/query payloads

### Requirement: Frontend Must Not Infer Topology Structure
The system SHALL not rely on frontend pair-candidate selection or interface-attribution inference to determine topology edge structure for GodView.

#### Scenario: Frontend consumes backend topology as-is
- **GIVEN** a GodView snapshot payload produced by backend
- **WHEN** frontend builds render data
- **THEN** frontend does not run protocol arbitration or pair-candidate selection for topology structure
- **AND** frontend does not infer missing interface attribution for edge directionality
- **AND** frontend only performs rendering/layout concerns on backend-provided edges

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

### Requirement: Discovery job assignment uses registered agents
Discovery job assignment SHALL be selected from the registry of known agents in the selected partition, and the API MUST reject assignments to unknown agent IDs.

#### Scenario: Assign job to a known agent
- **GIVEN** an admin opens the discovery job editor
- **WHEN** they open the agent assignment selector
- **THEN** the UI lists registered agent IDs for the partition
- **AND** selecting an agent allows the job to save

#### Scenario: Reject unknown agent assignment
- **GIVEN** an admin submits a discovery job with an agent ID that does not exist
- **WHEN** the job is saved
- **THEN** the API returns a validation error
- **AND** the job is not scheduled for execution

### Requirement: Discovery job run diagnostics
The system SHALL persist and expose discovery job run diagnostics including last run timestamp, status, interface count, and error summary.

#### Scenario: Successful discovery run reports diagnostics
- **GIVEN** a discovery job completes successfully
- **WHEN** the discovery job list is loaded
- **THEN** the response includes last run timestamp, status set to success, and a non-zero interface count

#### Scenario: Failed discovery run reports diagnostics
- **GIVEN** a discovery job fails to execute or returns no interfaces
- **WHEN** the discovery job list is loaded
- **THEN** the response includes last run timestamp, status set to error, and an error summary

### Requirement: Discovery jobs can be triggered on demand
The system SHALL allow admins to trigger a discovery job immediately from the discovery jobs list.

#### Scenario: Run discovery job now
- **GIVEN** a discovery job is configured
- **WHEN** the admin selects "Run now" in the discovery jobs list
- **THEN** the job is queued to execute immediately on the assigned agent or partition

### Requirement: Mapper Discovery Accepts Sweep-Promoted Targets
The system SHALL support on-demand mapper discovery for sweep-promoted hosts by reusing existing mapper job assignment and command-bus delivery.

#### Scenario: Promote live host through an eligible mapper job
- **GIVEN** a live sweep-discovered host is eligible for mapper promotion
- **AND** a mapper job exists in the same partition and compatible agent scope
- **WHEN** the promotion is dispatched
- **THEN** the system SHALL trigger mapper discovery through that mapper job's assigned agent context
- **AND** the promoted host SHALL be included as a discovery target for the on-demand run

#### Scenario: Agent-specific mapper job is preferred
- **GIVEN** multiple mapper jobs could accept a promoted host
- **AND** one of them is assigned to the same agent that executed the sweep
- **WHEN** the system selects a mapper job for promotion
- **THEN** the system SHALL prefer the agent-specific mapper job over a less-specific fallback

### Requirement: Mapper Promotion Dispatch Is Idempotent
The system SHALL avoid duplicate mapper discovery dispatches for the same promoted host within the configured suppression window.

#### Scenario: Repeated sweep hits do not spam mapper runs
- **GIVEN** a live host has already triggered mapper promotion recently
- **WHEN** subsequent sweep results ingest the same host before the suppression window expires
- **THEN** the system SHALL NOT dispatch another mapper promotion for that host
- **AND** the existing mapper job queue SHALL remain bounded

#### Scenario: Host can be promoted again after suppression window
- **GIVEN** a live host was previously promoted
- **WHEN** the suppression window has expired and the host is seen again by sweep
- **THEN** the system SHALL allow a new mapper promotion dispatch

### Requirement: Discovery ingestion stores SNMP fingerprint metadata
The mapper results ingestor SHALL persist normalized SNMP fingerprint metadata from discovery payloads for downstream enrichment and identity logic.

#### Scenario: Fingerprint persisted with discovery result
- **GIVEN** mapper publishes a discovery payload containing `snmp_fingerprint`
- **WHEN** core ingests the payload
- **THEN** fingerprint fields SHALL be persisted and exposed to enrichment/identity processing in the same ingestion transaction

### Requirement: Topology Evidence Must Not Drive Identity Equivalence
The system SHALL treat topology adjacency as relationship evidence only and SHALL NOT use topology links as sufficient proof that two observations represent the same device identity.

#### Scenario: Shared neighbor does not collapse identities
- **GIVEN** two discovered devices both report adjacency to the same gateway or subnet anchor
- **WHEN** identity reconciliation is evaluated for discovery output
- **THEN** the system SHALL keep device identities distinct unless identity proof requirements are met
- **AND** adjacency evidence SHALL be stored as topology relationship evidence only

#### Scenario: Inferred subnet evidence cannot force identity merge
- **GIVEN** inferred topology evidence derived from subnet, ARP, or gateway correlation
- **WHEN** identity reconciliation is evaluated
- **THEN** inferred topology evidence SHALL NOT trigger identity equivalence or device merges by itself

### Requirement: Deterministic Discovery Identity Anchors
The mapper discovery pipeline SHALL emit deterministic identity anchors and SHALL preserve source evidence fields used to justify identity and topology decisions.

#### Scenario: Multi-IP device observations converge to one anchored identity
- **GIVEN** a physical device is observed via multiple management or interface IP addresses across discovery paths
- **WHEN** discovery results are published
- **THEN** the observations SHALL reference one deterministic identity anchor
- **AND** the payload SHALL retain source evidence fields needed for reconciliation audits

### Requirement: On-demand discovery via command bus
The system SHALL allow admins to trigger a discovery job immediately via the command bus when the assigned agent is online.

#### Scenario: Run discovery job now
- **GIVEN** a discovery job assigned to an online agent
- **WHEN** the admin selects "Run now"
- **THEN** the system sends a discovery command over the control stream
- **AND** the UI receives command status updates

#### Scenario: Run discovery job while agent offline
- **GIVEN** a discovery job assigned to an offline agent
- **WHEN** the admin selects "Run now"
- **THEN** the system returns an immediate error

