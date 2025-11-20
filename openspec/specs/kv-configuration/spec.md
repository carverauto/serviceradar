# kv-configuration Specification

## Purpose
Document how ServiceRadar components seed configuration into KV storage and resolve effective configuration from default filesystem files, KV overlays, and pinned filesystem overrides.

## Requirements
### Requirement: Automatic Configuration Seeding
Services SHALL automatically seed the Key-Value (KV) store with default configuration if the configuration is missing in the KV store upon startup.

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
