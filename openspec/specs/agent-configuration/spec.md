# agent-configuration Specification

## Purpose
TBD - created by archiving change sysmon-consolidation. Update Purpose after archive.
## Requirements
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
- **THEN** the agent uses the default sysmon profile
- **AND** basic CPU, memory, and disk monitoring is active

### Requirement: Remote Configuration Fetch

The `serviceradar-agent` MUST fetch its sysmon configuration from the control plane via gRPC when no local override exists.

#### Scenario: Fetch config on startup
- **GIVEN** a registered agent without local sysmon.json
- **WHEN** the agent process starts
- **THEN** it requests its effective configuration from the gateway/datasvc
- **AND** receives a `SysmonConfig` message with all monitoring parameters

#### Scenario: Config fetch failure with fallback
- **GIVEN** an agent starting up
- **AND** the control plane is unreachable
- **WHEN** the agent attempts to fetch configuration
- **THEN** it retries with exponential backoff (max 5 attempts)
- **AND** falls back to cached configuration if available
- **AND** uses default profile if no cache exists

#### Scenario: Config fetch timeout
- **GIVEN** an agent attempting to fetch configuration
- **WHEN** the request takes longer than 30 seconds
- **THEN** the request times out
- **AND** the agent proceeds with fallback logic

### Requirement: Periodic Configuration Refresh

The agent MUST periodically check for configuration updates and apply changes without restart.

#### Scenario: Config refresh interval
- **GIVEN** an agent with sysmon running
- **AND** a refresh interval of 5 minutes (default)
- **WHEN** 5 minutes elapse since last config fetch
- **THEN** the agent fetches updated configuration
- **AND** applies any changes to the running collector

#### Scenario: Config change detected
- **GIVEN** an agent running with profile "Default"
- **WHEN** the admin assigns profile "High Performance" to the device
- **AND** the agent's next config refresh occurs
- **THEN** the agent detects the configuration change
- **AND** reconfigures the sysmon collector with new parameters
- **AND** logs the configuration change

#### Scenario: No config change
- **GIVEN** an agent running with current configuration
- **WHEN** config refresh occurs
- **AND** the remote configuration is unchanged
- **THEN** no collector reconfiguration occurs
- **AND** only a debug-level log is emitted

### Requirement: Local Configuration Override

The `serviceradar-agent` MUST support local filesystem configuration that takes precedence over remote profiles.

#### Scenario: Local sysmon.json exists
- **GIVEN** a file at `/etc/serviceradar/sysmon.json` exists
- **WHEN** the agent resolves its sysmon configuration
- **THEN** local configuration is used
- **AND** remote profile fetch is skipped
- **AND** the agent logs "Using local sysmon configuration"

#### Scenario: Local config priority
- **GIVEN** local sysmon.json with `sample_interval: 5s`
- **AND** remote profile with `sample_interval: 1s`
- **WHEN** configuration is resolved
- **THEN** the local value of 5s is used
- **AND** remote profile is completely ignored (no merge)

#### Scenario: Invalid local config
- **GIVEN** a malformed sysmon.json file
- **WHEN** the agent attempts to load local configuration
- **THEN** an error is logged with details
- **AND** the agent falls back to remote configuration
- **AND** continues startup

#### Scenario: Local config file paths
- **GIVEN** an agent on Linux
- **THEN** local config is read from `/etc/serviceradar/sysmon.json`
- **GIVEN** an agent on macOS
- **THEN** local config is read from `/usr/local/etc/serviceradar/sysmon.json` (fallback from Linux path)

### Requirement: Configuration Resolution Order

The agent MUST resolve configuration using a defined priority order.

#### Scenario: Full resolution chain
- **GIVEN** an agent with:
  - Local sysmon.json present
  - Device assigned profile "Database"
  - Device has tag "prod" with tag-assigned profile "Production"
  - Default system profile exists
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

### Requirement: Default Configuration

The system MUST provide a default configuration for agents with no specific profile assigned.

#### Scenario: New agent with no profile
- **GIVEN** a newly registered agent
- **AND** no tags assigned
- **AND** no direct profile assignment
- **WHEN** the agent requests configuration
- **THEN** it receives the Default Sysmon Profile

#### Scenario: Default profile contents
- **GIVEN** the Default Sysmon Profile
- **THEN** it includes:
  - `enabled: true`
  - `sample_interval: 10s`
  - `collect_cpu: true`
  - `collect_memory: true`
  - `collect_disk: true`
  - `collect_network: false` (opt-in due to verbosity)
  - `collect_processes: false` (opt-in due to resource usage)
  - `disk_paths: ["/"]` on Linux, `["/"]` on macOS

### Requirement: Configuration Caching

The agent MUST cache the last known good configuration for resilience.

#### Scenario: Cache on successful fetch
- **GIVEN** an agent that successfully fetches configuration
- **WHEN** the fetch completes
- **THEN** the configuration is cached to disk
- **AND** cache location is `/var/lib/serviceradar/cache/sysmon-config.json`

#### Scenario: Use cache on failure
- **GIVEN** an agent restarting
- **AND** the control plane is unreachable
- **AND** a cached configuration exists
- **WHEN** the agent resolves configuration
- **THEN** the cached configuration is used
- **AND** the agent logs "Using cached sysmon configuration"

#### Scenario: Cache expiration
- **GIVEN** a cached configuration older than 24 hours
- **AND** the control plane is unreachable
- **WHEN** the agent resolves configuration
- **THEN** the cached configuration is still used (better than nothing)
- **AND** a warning is logged about stale cache

### Requirement: Configuration Schema

The sysmon configuration MUST follow a defined JSON schema.

#### Scenario: Valid configuration structure
- **GIVEN** a sysmon configuration file
- **THEN** it MUST conform to this structure:
```json
{
  "enabled": true,
  "sample_interval": "10s",
  "collect_cpu": true,
  "collect_memory": true,
  "collect_disk": true,
  "collect_network": false,
  "collect_processes": false,
  "disk_paths": ["/", "/data"],
  "process_top_n": 10,
  "thresholds": {
    "cpu_warning": "80",
    "cpu_critical": "95",
    "memory_warning": "85",
    "memory_critical": "95",
    "disk_warning": "80",
    "disk_critical": "90"
  }
}
```

#### Scenario: Minimal valid configuration
- **GIVEN** a configuration with only required fields
- **THEN** `{"enabled": true}` is valid
- **AND** all other fields use defaults

#### Scenario: Duration parsing
- **GIVEN** sample_interval values
- **THEN** the following formats are valid: "10s", "1m", "500ms", "2m30s"
- **AND** invalid formats cause a validation error

