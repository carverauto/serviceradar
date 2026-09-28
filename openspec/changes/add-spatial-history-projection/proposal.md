# Change: Spatial observations: JetStream history, current-position projection and authorized reads

Tracking issue: [#4912](https://github.com/carverauto/serviceradar/issues/4912).

## Why

Implement the storage/query path for the atomic spatial contract in `add-spatial-observation-ingestion`; integrate with dashboard providers in `add-shared-spatial-resources`. This is separately schedulable follow-up work, not a #4774 acceptance dependency.

## What Changes

- Route every observation through JetStream/EventWriter. StarRocks is the only history backend when enabled; retain complete CNPG history behavior when disabled. Never dual-write history or bypass JetStream.
- Add bounded current-position/resource Ash resources and migrations in CNPG/PostGIS. Current state is a replayable projection, not a second history archive.
- Define idempotency, replay checkpoints, tombstones, late/out-of-order observations, freshness, conflicting producers and lag/backlog visibility.
- Register authorized provider APIs for bounded viewport/current-state reads and time-bounded history. Keep dynamic overlays separate from cached geometry.
- Reuse canonical relationship ingestion for Dgraph; do not create a graph edge per movement sample.

Related workstreams have separate proposals and acceptance checklists.

## Impact

EventWriter, both telemetry backend schemas/readers, CNPG/PostGIS Ash projection and authorized spatial providers. Depends on add-spatial-observation-ingestion; provider integration uses add-shared-spatial-resources. Does not block #4774.

Proposal and tracking only; no deployment, data ingestion or recording is enabled
by this documentation change.
