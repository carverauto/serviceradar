# Change: Fix sysmon metrics ingestion from gRPC pipeline

## Why
Sysmon metrics streamed from agents over gRPC are not being persisted to tenant CNPG hypertables, so device details render without sysmon charts and the metrics pipeline silently drops data.

## What Changes
- Parse sysmon metrics payloads forwarded via gRPC status updates and insert CPU, CPU cluster, memory, disk, and process metrics into tenant-scoped hypertables using Ash bulk creates.
- Resolve the device identifier from the agent record when available, with safe fallbacks if the device linkage is missing.
- Permit larger `sysmon-metrics` payloads in the agent gateway to avoid truncation.
- Add an Ash resource mapping for `cpu_cluster_metrics` (if needed for ingestion parity).

## Impact
- Affected specs: edge-architecture
- Affected code: agent gateway status normalization, core status handler, observability resources, sysmon ingestion pipeline
