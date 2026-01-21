# kv-configuration Specification

## Purpose
Document how ServiceRadar components seed configuration into KV storage and resolve effective configuration from default filesystem files, KV overlays, and pinned filesystem overrides.
## Requirements
### Requirement: Service Configuration Sources
All services MUST load service configuration from local JSON/YAML files or gRPC-delivered configuration (when managed by `serviceradar-agent`) and MUST NOT read, seed, or watch KV-backed configuration for service config. Zen MAY continue to read rules from KV, but MUST NOT use KV for its service configuration.

#### Scenario: Service uses file-based config
- **GIVEN** a service starts with a JSON config file on disk
- **WHEN** the service resolves configuration
- **THEN** it loads configuration from the file
- **AND** it does not connect to the KV service for configuration

#### Scenario: Agent-managed collector uses gRPC config
- **GIVEN** a collector configuration is delivered via the AgentConfig gRPC response
- **WHEN** the collector initializes under `serviceradar-agent`
- **THEN** it uses the gRPC configuration
- **AND** it does not attempt KV reads or watches

#### Scenario: Zen reads rules from KV but not config
- **GIVEN** zen starts with a local YAML configuration file
- **AND** zen has rule definitions stored in KV
- **WHEN** zen initializes
- **THEN** it loads service configuration from the local file
- **AND** it reads rules from KV
- **AND** it does not read service configuration from KV

