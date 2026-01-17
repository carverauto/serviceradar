## ADDED Requirements

### Requirement: Embedded SNMP Service Initialization

The `serviceradar-agent` MUST initialize the embedded SNMP collector at startup based on resolved configuration from the control plane.

#### Scenario: Agent startup with SNMP enabled
- **GIVEN** the agent is starting
- **AND** SNMP is enabled in the resolved configuration
- **WHEN** initialization completes
- **THEN** the SNMP service is running and polling configured targets
- **AND** SNMP target status is included in agent status reports

#### Scenario: Agent startup with SNMP disabled
- **GIVEN** the agent is starting
- **AND** SNMP is disabled in configuration (no matching profile)
- **WHEN** initialization completes
- **THEN** no SNMP collectors are started
- **AND** no SNMP-related metrics are reported

#### Scenario: SNMP not configured for device
- **GIVEN** the agent is starting
- **AND** no SNMP profile matches the device
- **AND** no default SNMP profile exists
- **WHEN** initialization completes
- **THEN** the SNMP service is not started
- **AND** agent operates without SNMP monitoring

### Requirement: SNMP Configuration Fetch

The `serviceradar-agent` MUST fetch its SNMP configuration from the control plane via gRPC as part of the unified AgentConfigResponse.

#### Scenario: Fetch SNMP config on startup
- **GIVEN** a registered agent
- **WHEN** the agent fetches its configuration
- **THEN** the AgentConfigResponse includes SNMPConfig
- **AND** SNMPConfig contains targets, OIDs, and authentication

#### Scenario: SNMP config fetch failure with fallback
- **GIVEN** an agent starting up
- **AND** the control plane is unreachable
- **WHEN** the agent attempts to fetch configuration
- **THEN** it uses cached SNMP configuration if available
- **AND** uses local override file if no cache exists

### Requirement: SNMP Configuration Refresh

The agent MUST periodically check for SNMP configuration updates and apply changes without restart.

#### Scenario: SNMP config refresh adds new target
- **GIVEN** an agent running with SNMP monitoring
- **AND** an admin adds a new SNMP target to the profile
- **WHEN** the agent's next config refresh occurs
- **THEN** the agent starts polling the new target
- **AND** existing targets continue uninterrupted

#### Scenario: SNMP config refresh removes target
- **GIVEN** an agent polling SNMP target "router-1"
- **AND** an admin removes "router-1" from the profile
- **WHEN** the agent's next config refresh occurs
- **THEN** the agent stops polling "router-1"
- **AND** the collector for "router-1" is cleaned up

#### Scenario: SNMP profile change
- **GIVEN** an agent with SNMP profile "Basic"
- **AND** an admin changes the device's profile to "Comprehensive"
- **WHEN** the agent's next config refresh occurs
- **THEN** the agent reconfigures with the new profile's targets
- **AND** logs the profile change

### Requirement: Local SNMP Configuration Override

The `serviceradar-agent` MUST support local filesystem SNMP configuration that takes precedence over remote profiles.

#### Scenario: Local snmp.json exists
- **GIVEN** a file at `/etc/serviceradar/snmp.json` exists
- **WHEN** the agent resolves its SNMP configuration
- **THEN** local configuration is used
- **AND** remote profile fetch is skipped
- **AND** the agent logs "Using local SNMP configuration"

#### Scenario: Invalid local SNMP config
- **GIVEN** a malformed snmp.json file
- **WHEN** the agent attempts to load local configuration
- **THEN** an error is logged with details
- **AND** the agent falls back to remote configuration

### Requirement: SNMP Configuration Caching

The agent MUST cache the last known good SNMP configuration for resilience.

#### Scenario: Cache on successful SNMP config fetch
- **GIVEN** an agent that successfully fetches SNMP configuration
- **WHEN** the fetch completes
- **THEN** the SNMP configuration is cached to disk
- **AND** cache location is `/var/lib/serviceradar/cache/snmp-config.json`

#### Scenario: Use cache when control plane unreachable
- **GIVEN** an agent restarting
- **AND** the control plane is unreachable
- **AND** a cached SNMP configuration exists
- **WHEN** the agent resolves configuration
- **THEN** the cached SNMP configuration is used
- **AND** the agent logs "Using cached SNMP configuration"

### Requirement: SNMP Status in Agent Status Response

The agent's status response MUST include the status of all configured SNMP targets.

#### Scenario: Include SNMP status in agent status
- **GIVEN** an agent polling three SNMP targets
- **WHEN** agent status is requested via gRPC
- **THEN** the status response includes SNMP service status
- **AND** each target's availability and last poll time is included

#### Scenario: SNMP status when disabled
- **GIVEN** an agent with no SNMP configuration
- **WHEN** agent status is requested
- **THEN** the status response indicates SNMP is not configured
- **AND** no SNMP target statuses are included
