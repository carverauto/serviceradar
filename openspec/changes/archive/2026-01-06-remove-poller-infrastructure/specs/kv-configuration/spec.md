## MODIFIED Requirements
### Requirement: Docker Compose KV bootstrap
Docker Compose deployments SHALL start KV-managed services with KV-backed configuration enabled so defaults are seeded into datasvc and watcher telemetry is published on first boot.

#### Scenario: Compose seeds KV on first boot
- **GIVEN** the Docker Compose stack starts against an empty `serviceradar-datasvc` bucket
- **WHEN** core, gateway, agent, sync, and other KV-managed services initialize
- **THEN** each service writes its default config to its KV key without overwriting existing values
- **AND** watcher snapshots appear under `watchers/<service>/<instance>.json` so the Settings → Watcher Telemetry UI lists those compose services
