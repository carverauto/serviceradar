# Change: Add camera analysis worker health and failover

## Why
The platform now has a camera analysis worker registry, but worker targeting is still too static for production use. Selection only knows identity, capability, and a coarse `enabled` flag, which means transiently unhealthy workers still look selectable and capability-based branches cannot fail over cleanly.

## What Changes
- Add platform-owned health state for registered camera analysis workers.
- Make worker selection health-aware for relay-scoped analysis dispatch.
- Add bounded failover for capability-targeted analysis branches when a selected worker becomes unavailable.
- Emit explicit observability for worker health transitions, failover, and terminal selection failure.

## Impact
- Affected specs:
  - `edge-architecture`
  - `observability-signals`
- Affected code:
  - `elixir/serviceradar_core/**`
  - `elixir/serviceradar_core_elx/**`
- Dependencies:
  - builds on `add-camera-analysis-worker-registry`
  - builds on `add-camera-analysis-http-worker-adapter`
