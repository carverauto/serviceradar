## MODIFIED Requirements

### Requirement: Secure credential storage for discovery
Discovery credentials (SNMP and API) MUST be stored using AshCloak encryption in CNPG and MUST be redacted in UI-facing responses.

#### Scenario: Save SNMP credentials
- **GIVEN** an admin configures SNMP discovery for a job
- **WHEN** the job is saved
- **THEN** SNMP credentials SHALL be sourced from SNMP profiles or per-device overrides (not stored on the job)
- **AND** any stored credentials (profile/device) SHALL be encrypted at rest via AshCloak
- **AND** API responses to the UI SHALL redact sensitive fields

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

## ADDED Requirements

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
