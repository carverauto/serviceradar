## Context
Sysmon sampling is currently tied to a single sample interval. In large fleets this produces high cardinality timeseries and heavy ingest load. We need a policy that allows high-frequency local sampling while reducing upload volume via downsampling, without breaking existing ingestion or UI assumptions.

## Goals / Non-Goals
- Goals:
  - Decouple local sampling cadence from upload cadence.
  - Support downsampled aggregation per upload window with predictable semantics.
  - Allow per-metric cadences (CPU, memory, disk, processes).
  - Preserve backward compatibility when new fields are absent.
- Non-Goals:
  - Changing SRQL semantics or storage schema as part of this change.
  - Redesigning UI charting or timeseries rendering.

## Decisions
- Decision: Add `upload_interval` and `downsample_window` to sysmon config.
  - Rationale: Keeps sampling and reporting independent with explicit controls.
- Decision: Use windowed aggregation with explicit modes (avg/min/max/last) per metric group.
  - Rationale: Matches common monitoring semantics and preserves operational signals.
- Decision: Add per-metric intervals to avoid expensive collectors running too frequently.
  - Rationale: Process and disk metrics are heavier than CPU/memory.

## Risks / Trade-offs
- Risk: Downsampled data may hide short spikes.
  - Mitigation: Allow tighter upload interval per profile; keep raw sampling available locally.
- Risk: Added config complexity.
  - Mitigation: Provide sensible defaults and clear schema documentation.

## Migration Plan
- Default behavior remains unchanged if new fields are not set.
- Agents that receive new fields will begin downsampling and upload at the configured cadence.

## Open Questions
- What should the default per-metric intervals be for large fleets?
- Should process metrics be sampled at a different cadence than CPU/memory?
- Should we allow a "burst" mode when anomalies are detected?
