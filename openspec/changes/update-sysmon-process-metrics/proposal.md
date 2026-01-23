# Change: Expose sysmon process metrics end-to-end

## Why
Sysmon profiles can enable process collection, but device details currently show no process (PID) data, making it unclear whether the agent collected metrics or the pipeline dropped them.

## What Changes
- Verify sysmon process metrics collection and serialization from `serviceradar-agent` when `collect_processes` is enabled.
- Ensure the gateway/core ingestion pipeline persists process metrics into `process_metrics` without dropping fields.
- Surface sysmon process metrics in the device detail UI as a dedicated panel (top N by CPU/memory).
- Add SRQL queries/tests to confirm process metrics are queryable for device detail views.

## Impact
- Affected specs: `edge-architecture`, `build-web-ui`
- Affected code: `pkg/sysmon`, `cmd/agent`, gateway/core ingestion, `rust/srql`, `web-ng` device details
