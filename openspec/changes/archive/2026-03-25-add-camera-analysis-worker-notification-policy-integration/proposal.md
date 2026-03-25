# Change: Add camera analysis worker notification policy integration

## Why
Camera analysis worker degradation now produces authoritative worker alert state and routed observability alerts, but those alerts still stop at the event/alert layer. Operators need those routed worker alerts to participate in the platform's normal notification-policy and re-notify flow so worker incidents page and clear the same way other observability incidents do.

## What Changes
- Integrate routed camera analysis worker alerts with the standard notification-policy evaluation path.
- Reuse the existing observability alert lifecycle rather than adding a worker-specific notification subsystem.
- Preserve duplicate suppression and bounded re-notify behavior while a worker remains in the same derived alert state.
- Expose enough policy-routing context in the worker ops surface to explain whether a worker alert is eligible for standard notification handling.

## Impact
- Affected specs: `observability-signals`, `edge-architecture`, `build-web-ui`
- Affected code: worker alert routing in `serviceradar_core`, observability alert/notification evaluation, and the `web-ng` worker ops surface
