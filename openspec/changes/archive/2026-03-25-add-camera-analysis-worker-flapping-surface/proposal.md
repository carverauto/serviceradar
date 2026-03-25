# Change: Add Camera Analysis Worker Flapping Surface

## Why
Recent probe history is now available on registered camera analysis workers, but operators still have to infer flapping manually from raw probe rows. That is too low-level for routing and incident response when workers oscillate between healthy and unhealthy states.

## What Changes
- Add a bounded derived flapping state for registered camera analysis workers from recent probe history.
- Expose flapping state and normalized flapping metadata through the existing worker management API.
- Show flapping status prominently in the `web-ng` camera analysis worker operations surface.
- Emit explicit observability signals when workers enter or leave a flapping state.

## Impact
- Affected specs: `edge-architecture`, `build-web-ui`, `observability-signals`
- Affected code: `serviceradar_core`, `serviceradar_core_elx`, `web-ng`
