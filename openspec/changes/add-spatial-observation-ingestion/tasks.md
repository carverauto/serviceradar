## 1. Contracts and compatibility
- [ ] 1.1 Review/freeze spatial wire schema, stable identity resolution, coordinate and altitude conventions, size/rate limits, producer handoff, equal-time conflicts and future-clock policy against the edge ABI.
- [ ] 1.2 Add negotiated host admission and Go/Rust builders with shared invented cross-language conformance vectors; reject unsupported capability/version without silent loss.

## 2. Storage and projection
- [ ] 2.1 Implement JetStream/EventWriter history with matching StarRocks and CNPG backend schemas/readers; no dual history writes.
- [ ] 2.2 Generate spatial-resource/current-position Ash migrations; implement bounded projection, idempotency, replay/checkpoint recovery, tombstones and lag visibility.
- [ ] 2.3 Integrate canonical identity/relationship handling with the existing topology-link proposal rather than create a second Dgraph writer.

## 3. Queries and dashboard integration
- [ ] 3.1 Freeze/read-test time-bounded history and viewport query shapes on both supported backends; benchmark current-state write rate and lag.
- [ ] 3.2 Register an authorized spatial provider using showcase D19; prove fixed and moving non-device objects, geographic and Cartesian spaces, shared center/zoom URLs and stale-state display.

## 4. Acceptance
- [ ] 4.1 Exercise real synthetic SDK -> host -> JetStream -> EventWriter -> history/current projection -> browser reads; automated DB tests use srql-fixtures scratch DB only.
- [ ] 4.2 Verify disconnect/replay, duplicate, out-of-order, conflicting-producer, invalid-coordinate, backlog and unauthorized-object failure branches.
- [ ] 4.3 Run remote RBE checks, strict OpenSpec validation and no-mistakes review before PR publication.
