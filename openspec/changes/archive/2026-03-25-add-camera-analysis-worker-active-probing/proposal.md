# Change: Add Camera Analysis Worker Active Probing

## Why
Camera analysis workers currently become unhealthy only after dispatch failures. That is enough for bounded failover, but it leaves the registry stale when workers recover or when operators need current health before the next relay branch runs.

## What Changes
- Add active health probing for registered camera analysis workers.
- Update worker health state and timestamps from periodic probe results, not only dispatch outcomes.
- Keep explicit worker-id targeting fail-fast while allowing capability-based selection to prefer healthy workers based on active probe state.
- Emit explicit telemetry for probe success, failure, and health transitions.

## Impact
- Affected specs: `edge-architecture`, `observability-signals`
- Affected code: `elixir/serviceradar_core`, `elixir/serviceradar_core_elx`
