## ADDED Requirements
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
