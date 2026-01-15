## ADDED Requirements
### Requirement: Edge components do not depend on KV configuration
Edge agents and embedded checkers SHALL obtain dynamic configuration via gRPC from the control plane, and collectors SHALL read configuration from local filesystem files (config.json/yaml). These components MUST NOT require KV availability for startup or runtime configuration refresh.

#### Scenario: Agent starts without KV access
- **GIVEN** an agent with no KV endpoint configured
- **WHEN** the agent starts and completes enrollment
- **THEN** it retrieves configuration via gRPC
- **AND** continues operating without a KV dependency

#### Scenario: Collector loads filesystem config
- **GIVEN** a collector with `config.json` on disk
- **WHEN** it starts
- **THEN** it loads configuration from the filesystem
- **AND** does not attempt to watch or seed KV

## MODIFIED Requirements
### Requirement: Docker Compose KV bootstrap
Docker Compose deployments SHALL start KV-managed platform services with KV-backed configuration enabled so defaults are seeded into datasvc and watcher telemetry is published on first boot. Edge agents, checkers, and filesystem-configured collectors SHALL NOT be required to seed KV during Compose startup.

#### Scenario: Compose seeds KV on first boot
- **GIVEN** the Docker Compose stack starts against an empty `serviceradar-datasvc` bucket
- **WHEN** core, gateway, datasvc, and other KV-managed platform services initialize
- **THEN** each service writes its default config to its KV key without overwriting existing values
- **AND** watcher snapshots appear under `watchers/<service>/<instance>.json` so the Settings → Watcher Telemetry UI lists those compose services
