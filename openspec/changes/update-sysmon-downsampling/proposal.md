# Change: Update sysmon sampling + downsampled uploads

## Why
Sysmon metrics are sampled frequently today (e.g., 10s) which is fine for a single agent but does not scale to large fleets. We need to decouple local sampling from upload cadence and downsample on the agent so we can keep high-resolution collection where needed while controlling ingest volume and storage growth.

## What Changes
- Define a clear separation between **sample interval** (local collection cadence) and **upload interval** (report cadence).
- Add a downsampling policy for sysmon metrics (e.g., avg/min/max/last per window) so the agent can emit a compact sample per upload interval.
- Allow per-metric cadence (CPU, memory, disk, processes) to reduce expensive collections without losing visibility.
- Document gopsutil collection costs and constraints to guide default intervals.

## Impact
- Affected specs: `sysmon-library`, `agent-configuration`
- Affected code: `pkg/sysmon`, `pkg/agent`, sysmon config schema + compiler/serialization
- Runtime impact: reduced ingestion volume and predictable load at scale
