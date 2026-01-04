## MODIFIED Requirements

### Requirement: Automatic Configuration Seeding
Services SHALL automatically seed the Key-Value (KV) store with default configuration if the configuration is missing in the KV store upon startup. Services MUST ignore the initial KV watch event (which contains the current value at subscription time) and only trigger configuration reloads on subsequent changes.

#### Scenario: Seeding missing config
- **GIVEN** one or more instances of a service starting up
- **AND** the KV store is empty for the service's configuration key
- **AND** a default configuration file exists on the filesystem
- **WHEN** the service instances initialize their configuration
- **THEN** the service instances read the default configuration from the filesystem
- **AND** only one service instance atomically writes this configuration to the KV store
- **AND** all service instances use this configuration for startup

#### Scenario: Existing config preservation
- **GIVEN** a service starting up
- **AND** the KV store already contains configuration for the service
- **WHEN** the service initializes its configuration
- **THEN** the service uses the existing KV configuration
- **AND** the service DOES NOT overwrite the KV configuration with the filesystem default

#### Scenario: Initial KV watch event ignored
- **GIVEN** a service that watches KV for configuration changes
- **AND** the service has completed configuration loading
- **WHEN** the KV watcher receives its first event (the current value)
- **THEN** the service SHALL NOT trigger a restart or reload
- **AND** the service continues running with the already-loaded configuration

#### Scenario: Subsequent KV updates trigger reload
- **GIVEN** a running service with an active KV watcher
- **AND** the service has already received and ignored the initial KV watch event
- **WHEN** a subsequent KV update is received
- **THEN** the service triggers a configuration reload or restart to apply the new configuration
