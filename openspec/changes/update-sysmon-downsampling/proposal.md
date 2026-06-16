# Change: Update sysmon sampling + downsampled uploads

## Why
Sysmon metrics are sampled frequently today (e.g., 10s) which is fine for a single agent but does not scale to large fleets. We need to decouple local sampling from upload cadence and downsample on the agent so we can keep high-resolution collection where needed while controlling ingest volume and storage growth.

The EventWriter hot-path investigation measured the sharper failure mode: even after capping process collection to top 25 every 30 seconds, process telemetry still emits roughly `25 CPU + 25 memory + 1 count` rows per sample. At 50k agents this is about 85k process rows/sec before CPU, memory, disk, SNMP, OTEL, flow, anomaly, or capacity series are counted. The default process telemetry path therefore needs a rollup/detail split, not just a safer top-N cap.

## What Changes
- Define a clear separation between **sample interval** (local collection cadence) and **upload interval** (report cadence).
- Add a downsampling policy for sysmon metrics (e.g., avg/min/max/last per window) so the agent can emit a compact sample per upload interval.
- Allow per-metric cadence (CPU, memory, disk, processes) to reduce expensive collections without losing visibility.
- Add a process telemetry mode that defaults to rollups/top-N summaries and only emits per-process raw rows for explicit troubleshooting windows or targeted profiles.
- Treat process telemetry as diagnostic by default: it remains on the JetStream/CNPG path but is not a default anomaly-detection or capacity-planning input.
- Document gopsutil collection costs and constraints to guide default intervals.

## Impact
- Affected specs: `sysmon-library`, `agent-configuration`
- Affected code: `pkg/sysmon`, `pkg/agent`, sysmon config schema + compiler/serialization
- Runtime impact: reduced ingestion volume and predictable load at scale
