# Change: Add Camera Analysis Worker Alerting Thresholds

## Why
Camera analysis workers now expose health, failover, recent probe history, and derived flapping state, but the platform still relies on manual inspection to notice sustained worker degradation. Operators need bounded alerting thresholds so unhealthy, flapping, and exhausted-worker states surface automatically.

## What Changes
- Add bounded alerting thresholds for camera analysis worker degradation.
- Emit explicit alert-oriented observability signals for sustained unhealthy, flapping, and failover-exhausted worker states.
- Keep alert evaluation derived from the existing worker registry and runtime signals instead of introducing a parallel health model.
- Optionally expose summarized alert state in the worker management API/UI where it helps operator triage.

## Impact
- Affected specs: `observability-signals`, `edge-architecture`, `build-web-ui`
- Affected code: `serviceradar_core`, `serviceradar_core_elx`, `web-ng`
