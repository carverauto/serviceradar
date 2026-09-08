# Change: Add Per-Source Discovery Intervals

## Why

Currently, the sync service uses global intervals for all integration sources (discovery, poll, sweep). Each `IntegrationSource` can store per-source interval values, and the config generator sends them to the agent, but the agent ignores them and uses global defaults instead. This prevents operators from configuring different discovery cadences for different integration sources based on their specific needs (e.g., high-frequency polling for critical Armis sources vs. daily discovery for stable SNMP sources).

## What Changes

- Agent sync runtime reads per-source `discovery_interval`, `poll_interval`, and `sweep_interval` from source config
- Per-source intervals override global config defaults when specified
- Each source runs on its own schedule rather than all sources running on the global timer
- Sources without explicit intervals continue using global defaults (6h discovery, 5m poll, 1h sweep)

## Impact

- Affected specs: `sync-service-integrations` (adding per-source scheduling capability)
- Affected code:
  - `pkg/sync/service.go` - Timer management and discovery loop
  - `pkg/sync/config.go` - Interval resolution logic
  - `pkg/models/sync.go` - Already has `DiscoveryInterval` field (completed)
  - Integration sources UI - Already exposes all interval fields (completed)
