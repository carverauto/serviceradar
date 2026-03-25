# Change: Add Camera Analysis Worker Probe History Surface

## Why
The platform now tracks current worker health and operator-managed probe settings, but operators still cannot see whether a worker is flapping or what recent probe failures looked like. A single latest-state field is not enough for diagnosing unstable workers.

## What Changes
- Add bounded recent probe result history for registered camera analysis workers.
- Expose recent probe outcomes through the worker management API.
- Show recent probe activity and failure reasons in the operator-facing worker management surface.

## Impact
- Affected specs: `edge-architecture`, `build-web-ui`, `observability-signals`
- Affected code: `elixir/serviceradar_core`, `elixir/serviceradar_core_elx`, `elixir/web-ng`
