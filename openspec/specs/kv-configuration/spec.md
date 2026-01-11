# kv-configuration Specification

## Purpose
Document how ServiceRadar components seed configuration into KV storage and resolve effective configuration from default filesystem files, KV overlays, and pinned filesystem overrides.
## Requirements
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

### Requirement: Configuration Precedence
Services SHALL resolve configuration values by deeply merging sources in a specific order of precedence: Pinned Filesystem Config > KV Config > Default Filesystem Config. Nested objects MUST merge recursively so keys absent in higher-precedence sources inherit values from lower-precedence sources.

#### Scenario: KV overrides default
- **GIVEN** a configuration key `log_level` is "INFO" in the default filesystem config
- **AND** `log_level` is "DEBUG" in the KV store
- **WHEN** the service resolves its configuration
- **THEN** the effective `log_level` is "DEBUG"

#### Scenario: Pinned config overrides KV
- **GIVEN** a configuration key `admin_port` is "8080" in the KV store
- **AND** `admin_port` is "9090" in the pinned filesystem config
- **WHEN** the service resolves its configuration
- **THEN** the effective `admin_port` is "9090"

#### Scenario: Deep merge retains lower-precedence fields
- **GIVEN** the default filesystem config has `logging.level` of "INFO" and `logging.format` of "json"
- **AND** the KV store has `logging.level` set to "DEBUG" and does not specify `logging.format`
- **WHEN** the service resolves its configuration
- **THEN** the effective `logging.level` is "DEBUG"
- **AND** the effective `logging.format` remains "json" inherited from the default filesystem config

### Requirement: Configuration Observability
Services SHALL expose the final, merged configuration for diagnostics via a startup log (with sensitive values redacted) and/or a read-only administrative endpoint.

#### Scenario: Merged configuration is observable
- **GIVEN** a service completes configuration resolution (Default + KV + Pinned)
- **WHEN** the service starts
- **THEN** it emits a log entry or exposes a read-only endpoint showing the merged configuration
- **AND** sensitive values remain redacted in the emitted configuration

### Requirement: Docker Compose KV bootstrap
Docker Compose deployments SHALL start KV-managed services with KV-backed configuration enabled so defaults are seeded into datasvc and watcher telemetry is published on first boot.

#### Scenario: Compose seeds KV on first boot
- **GIVEN** the Docker Compose stack starts against an empty `serviceradar-datasvc` bucket
- **WHEN** core, gateway, agent, sync, and other KV-managed services initialize
- **THEN** each service writes its default config to its KV key without overwriting existing values
- **AND** watcher snapshots appear under `watchers/<service>/<instance>.json` so the Settings → Watcher Telemetry UI lists those compose services

### Requirement: Non-Destructive Compose Upgrades
Docker Compose upgrades SHALL preserve user-managed configuration state (both persistent config artifacts and KV-backed configuration). Bootstrap jobs used by Compose (e.g., config-updater and KV seeders) MUST NOT overwrite existing non-empty configuration values during routine upgrades.

#### Scenario: Upgrade preserves sysmon endpoint
- **GIVEN** a running Compose stack with a user-configured checker in the gateway configuration
- **WHEN** the stack is upgraded (images updated and containers recreated)
- **THEN** the checker configuration remains present after the upgrade
- **AND** metrics continue to populate without requiring manual reconfiguration

#### Scenario: Bootstrap does not write empty overrides
- **GIVEN** a running Compose stack with non-empty configuration values stored in KV and/or persisted config artifacts
- **AND** a bootstrap script is re-run during upgrade
- **WHEN** an optional/override env var is unset or empty
- **THEN** the bootstrap script DOES NOT write empty values into configuration files or KV

