# Change: Restore sysmon-vm metrics availability

## Why
Sysmon-vm collectors running on edge hosts (e.g., darwin/arm64) are healthy and connected, but their metrics no longer appear in the UI or `/api/sysmon` (GH-2042). The metrics pipeline should deliver device-level data whenever the collector is online; the current drop silently hides sysmon health.

## What Changes
- Diagnose and fix the sysmon metrics pipeline so connected sysmon-vm collectors persist and serve CPU/memory/time-series data for their target device again.
- Add detection/logging when a sysmon collector stays connected but metrics stop arriving or cannot be written/queryable, so operators see the degradation instead of empty graphs.
- Add regression coverage for sysmon-vm -> poller/core -> CNPG -> UI/API to guard against future silent losses, including the darwin/Compose mTLS onboarding path.
- Ensure device-centric sysmon endpoints return HTTP 200 with empty results (instead of 404) when no rows exist, preventing UI/API errors when a collector omits optional metric types.
- Extend the sysmon-vm checker to emit memory stats (and guard UI API routes against null payloads) so `/api/devices/{id}/sysmon/memory` returns data instead of null/500.

## Impact
- Affected specs: sysmon-telemetry
- Affected code: sysmon-vm collector bootstrap, poller sysmon ingestion, core/sysmon API and CNPG writes, UI sysmon panels, related observability/alerts
