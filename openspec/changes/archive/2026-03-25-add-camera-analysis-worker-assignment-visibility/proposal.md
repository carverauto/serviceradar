# Change: Add camera analysis worker assignment visibility

## Why
Camera analysis workers now have registry state, health, failover, probe history, derived alert state, and routed observability alerts. What operators still cannot see cleanly is which relay-scoped analysis branches are currently using a given worker. That makes active incidents harder to triage because worker health and worker alerts are disconnected from current branch load and relay usage.

## What Changes
- Add runtime visibility for current relay-session and branch assignments per registered camera analysis worker.
- Expose per-worker assignment counts and bounded active assignment details through the worker management API.
- Show current assignment visibility in the `web-ng` camera analysis worker ops surface.
- Preserve the existing registry as the authoritative worker inventory while deriving assignment state from the relay dispatch runtime.

## Impact
- Affected specs: `edge-architecture`, `build-web-ui`, `observability-signals`
- Affected code: `serviceradar_core_elx` analysis dispatch tracking, `web-ng` worker management API/UI, and related focused tests
