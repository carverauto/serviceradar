# Change: Fix ICMP Metrics Display Stoppage

## Why
ICMP metrics for `k8s-agent` appear to “stop updating” on the Device Details page after the UI has been open for a while:
- The Devices list ICMP sparkline continues refreshing.
- The Device Details “Latest ICMP RTT” and metrics timeline remain stuck at the timestamp from when the page was first opened.

## Root Cause
`web/src/components/Devices/DeviceDetail.tsx` fetches device metrics and availability history once on mount (and on filter changes), but does not poll/revalidate. The time window end is also derived from “now” only at render time, so leaving the page open results in a frozen time range and stale “latest” values even while the backend continues to ingest metrics.

## What Changes
- Add periodic auto-refresh to the Device Details view (SRQL queries for device record, availability, timeseries metrics, and sysmon summaries).
- Update the time window to advance as time passes so “last 24h” stays relative to current time.
- Remove the attempted API-key/RBAC context injection workaround (it is not the root cause of the UI display issue).

## Impact
- Affected specs: None (bug fix restoring intended behavior)
- Affected code:
  - `web/src/components/Devices/DeviceDetail.tsx` (auto-refresh + sliding time window)
  - `pkg/core/api/server.go` (revert API-key auth context injection workaround)
- No breaking changes
