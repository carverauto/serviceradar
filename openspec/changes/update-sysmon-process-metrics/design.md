## Context
Process metrics are optionally collected by sysmon but are not visible in the device detail UI. The gap could be in collection, ingestion, or query/visualization.

## Goals / Non-Goals
- Goals: Verify process metrics are collected, persisted, queryable, and visible on device detail pages.
- Non-Goals: Build a full process explorer or long-term per-process trend analysis.

## Decisions
- Use `process_metrics` as the canonical source for device detail views.
- Show a single "Processes" panel listing top N processes with PID, CPU%, and memory%.
- Query the most recent sample window (e.g., last 24h) and select the latest snapshot for display.

## Risks / Trade-offs
- Process metrics volume can grow quickly; enforce top N selection and avoid unbounded queries.

## Migration Plan
- No schema changes; use existing `process_metrics` table and SRQL entities.

## Open Questions
- Should the UI show historical CPU/memory charts per process in addition to the latest snapshot?
