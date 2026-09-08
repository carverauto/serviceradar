## Context
Sysmon sampling is currently tied to a single sample interval. In large fleets this produces high cardinality timeseries and heavy ingest load. We need a policy that allows high-frequency local sampling while reducing upload volume via downsampling, without breaking existing ingestion or UI assumptions.

## Goals / Non-Goals
- Goals:
  - Decouple local sampling cadence from upload cadence.
  - Support downsampled aggregation per upload window with predictable semantics.
  - Allow per-metric cadences (CPU, memory, disk, processes).
  - Keep process telemetry useful at scale by separating fleet-safe rollups from raw per-process detail.
  - Preserve backward compatibility when new fields are absent.
- Non-Goals:
  - Changing SRQL semantics or storage schema as part of this change.
  - Redesigning UI charting or timeseries rendering.
  - Replacing NATS JetStream as the first hop for sysmon metrics.

## Decisions
- Decision: Add `upload_interval` and `downsample_window` to sysmon config.
  - Rationale: Keeps sampling and reporting independent with explicit controls.
- Decision: Use windowed aggregation with explicit modes (avg/min/max/last) per metric group.
  - Rationale: Matches common monitoring semantics and preserves operational signals.
- Decision: Add per-metric intervals to avoid expensive collectors running too frequently.
  - Rationale: Process and disk metrics are heavier than CPU/memory.
- Decision: Add a process telemetry mode with `rollup` as the large-fleet default and `detail` as an explicit troubleshooting mode.
  - Rationale: A top-25 cap still creates about 85k process rows/sec at 50k agents. Rollups preserve normal fleet visibility while avoiding a raw row stream that the current CNPG path cannot absorb.
- Decision: Keep both rollup and detail outputs on the metric envelope / JetStream path.
  - Rationale: Direct-to-database metrics would bypass the platform ingestion contract.
- Decision: Exclude process telemetry from default anomaly detection and capacity planning inputs.
  - Rationale: Process names and detail rows are high-cardinality diagnostic data, not stable fleet capacity signals. CPU, memory, filesystem/disk usage, interface rates, service health, and flow aggregates are the default engine inputs.

## Risks / Trade-offs
- Risk: Downsampled data may hide short spikes.
  - Mitigation: Allow tighter upload interval per profile; keep raw sampling available locally.
- Risk: Added config complexity.
  - Mitigation: Provide sensible defaults and clear schema documentation.
- Risk: Rollups may hide the identity of a short-lived process spike.
  - Mitigation: Allow targeted `detail` mode with bounded TTL, profile targeting, and short retention.

## Migration Plan
- Default behavior remains unchanged if new fields are not set.
- Agents that receive new fields will begin downsampling and upload at the configured cadence.
- New installs and upgraded process-enabled default profiles should prefer `process_mode: rollup`; explicit `process_mode: detail` preserves raw per-process rows for operators who opt in.
- Existing anomaly/capacity defaults should stop scheduling `sysmon.process` sources unless a future explicit opt-in path is added.

## Open Questions
- What should the default per-metric intervals be for large fleets?
- Should process metrics be sampled at a different cadence than CPU/memory?
- Should we allow a "burst" mode when anomalies are detected?
- Should raw process detail have a hard maximum TTL at the profile layer, or can retention policy alone enforce bounded storage?
