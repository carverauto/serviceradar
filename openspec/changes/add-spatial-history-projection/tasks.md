## 1. Implementation

- [ ] 1.1 Route every observation through JetStream/EventWriter. StarRocks is the only history backend when enabled; retain complete CNPG history behavior when disabled. Never dual-write history or bypass JetStream.
- [ ] 1.2 Add bounded current-position/resource Ash resources and migrations in CNPG/PostGIS. Current state is a replayable projection, not a second history archive.
- [ ] 1.3 Define idempotency, replay checkpoints, tombstones, late/out-of-order observations, freshness, conflicting producers and lag/backlog visibility.
- [ ] 1.4 Register authorized provider APIs for bounded viewport/current-state reads and time-bounded history. Keep dynamic overlays separate from cached geometry.
- [ ] 1.5 Reuse canonical relationship ingestion for Dgraph; do not create a graph edge per movement sample.

## 2. Acceptance

- [ ] Synthetic SDK -> host -> JetStream -> EventWriter -> history/current projection -> browser path passes using actual components.
- [ ] Both supported history backends return equivalent time-bounded results; the inactive backend is not silently queried.
- [ ] Restart/replay, duplicate, late, conflicting and invalid observations preserve correct current position and visible stale state.
- [ ] Projection rate, query bounds and lag are measured; unauthorized objects/queries are denied.
- [ ] Fixed and moving non-device objects appear via the provider API and shared locations retain their declared semantics.

## 3. Delivery

- [ ] 3.1 Validate this proposal with openspec validate --strict and run applicable remote checks.
- [ ] 3.2 Run make test and deliver code changes through no-mistakes with the srql-fixtures-only database restriction in the intent.
- [ ] 3.3 Record evidence and close only this issue after its own acceptance passes.
