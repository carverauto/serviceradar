## ADDED Requirements

### Requirement: Automatic Configuration Seeding
Services SHALL automatically seed the Key-Value (KV) store with default configuration if the configuration is missing in the KV store upon startup.

#### Scenario: Seeding and merging configuration
- **GIVEN** one or more instances of a service starting up
- **AND** a default configuration file exists on the filesystem
- **AND** a potentially partial or empty configuration exists in the KV store
- **WHEN** the service instances initialize their configuration
- **THEN** the service instances read the default configuration from the filesystem
- **AND** only one service instance atomically writes the merged configuration to the KV store
- **AND** all service instances use the merged configuration for startup (subject to pinned overrides)

#### Scenario: Existing config preservation
- **GIVEN** a configuration key exists in both the default filesystem config and the KV store
- **WHEN** the service merges its configuration
- **THEN** the value from the KV store is used
- **AND** the service DOES NOT overwrite the existing KV value with the default value

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
