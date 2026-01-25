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

