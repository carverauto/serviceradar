# Change: Add camera analysis worker alert routing

## Why
Camera analysis workers now expose thresholded alert state, flapping state, failover exhaustion, and operator-facing visibility, but those states still stop at telemetry and the worker ops surface. Operators need the same platform alert routing behavior used elsewhere so degraded worker states can participate in standard event and alert workflows.

## What Changes
- Route camera analysis worker alert transitions into the existing observability event and alert pipeline.
- Normalize worker alert activation and clear transitions into platform alert metadata with worker, capability, and failover context.
- Keep routing transition-based so repeated probe noise or repeated dispatch failures do not create duplicate alerts.
- Preserve the existing worker management API/UI as a triage surface while making routed alerts visible through the standard observability panes.

## Impact
- Affected specs: `observability-signals`, `edge-architecture`, `build-web-ui`
- Affected code: `serviceradar_core` observability ingestion/rule plumbing, `serviceradar_core_elx` worker alert runtime, and `web-ng` observability/worker surfaces
