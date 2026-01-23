## MODIFIED Requirements
### Requirement: Embedded Sysmon Initialization

The `serviceradar-agent` MUST initialize the embedded `pkg/sysmon` collector at startup based on resolved configuration.

#### Scenario: Agent startup with sysmon enabled
- **GIVEN** the agent is starting
- **AND** sysmon is enabled in configuration
- **WHEN** initialization completes
- **THEN** the sysmon collector is running and collecting metrics
- **AND** metrics are included in agent status reports

#### Scenario: Agent startup with sysmon disabled
- **GIVEN** the agent is starting
- **AND** sysmon is disabled in configuration (explicit `enabled: false`)
- **WHEN** initialization completes
- **THEN** no sysmon collector is started
- **AND** no sysmon metrics are reported

#### Scenario: Sysmon not configured
- **GIVEN** the agent is starting
- **AND** no sysmon configuration exists (local or remote)
- **WHEN** initialization completes
- **THEN** no sysmon collector is started
- **AND** no sysmon metrics are reported

### Requirement: Configuration Resolution Order

The agent MUST resolve configuration using a defined priority order.

#### Scenario: Full resolution chain
- **GIVEN** an agent with:
  - Local sysmon.json present
  - Device assigned profile "Database"
  - Device has tag "prod" with tag-assigned profile "Production"
- **WHEN** configuration is resolved
- **THEN** local sysmon.json is used (highest priority)

#### Scenario: No local config, device profile exists
- **GIVEN** an agent without local sysmon.json
- **AND** device has profile "Database" directly assigned
- **WHEN** configuration is resolved
- **THEN** the "Database" profile is used

#### Scenario: Tag-based profile resolution
- **GIVEN** an agent without local sysmon.json
- **AND** device has no direct profile assignment
- **AND** device has tag "database-server"
- **AND** tag "database-server" has profile "High Performance" assigned
- **WHEN** configuration is resolved
- **THEN** the "High Performance" profile is used

#### Scenario: Multiple tag matches
- **GIVEN** a device with tags "production" and "database"
- **AND** tag "production" has profile "Prod Standard"
- **AND** tag "database" has profile "Database Intensive"
- **WHEN** configuration is resolved
- **THEN** the profile with higher priority is used
- **AND** priority is determined by profile assignment order (most recently assigned wins)

#### Scenario: No matching profiles
- **GIVEN** an agent without local sysmon.json
- **AND** device has no direct profile assignment
- **AND** device has no matching tag assignments
- **WHEN** configuration is resolved
- **THEN** no sysmon profile is selected

## ADDED Requirements
### Requirement: No Matching Profile Behavior

When no sysmon profile matches a device and no local override exists, the control plane MUST return a disabled sysmon configuration and the agent MUST not collect sysmon metrics.

#### Scenario: No matching profile returns disabled config
- **GIVEN** an agent without local sysmon.json
- **AND** no sysmon profile target query matches the device
- **WHEN** the agent requests configuration
- **THEN** the returned sysmon config has `enabled: false`
- **AND** no sysmon collector is started
- **AND** no sysmon metrics are reported

## REMOVED Requirements
### Requirement: Default Configuration
**Reason**: Sysmon profile resolution no longer relies on a default profile flag.
**Migration**: Create an SRQL profile (for example, `in:devices`) when a catch-all profile is desired.
