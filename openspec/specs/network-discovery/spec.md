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
- **GIVEN** an admin enters SNMP credentials for a discovery job
- **WHEN** the job is saved
- **THEN** the credentials SHALL be encrypted at rest via AshCloak
- **AND** API responses to the UI SHALL redact sensitive fields

#### Scenario: Edit job without clobbering secrets
- **GIVEN** an existing job with stored secrets
- **WHEN** the admin edits non-secret fields and saves
- **THEN** the existing secrets SHALL remain intact
- **AND** redacted placeholders SHALL not overwrite stored values

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
  - `credentials` (references to stored secrets)
  - `assignment` (agent or partition)

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

