## 1. Defect A: leased sweeps produce per-host gauges (bug fix)

- [x] 1.1 `ServiceRadar.Edge.SweepHostMetrics`: derive the per-host gauges of a `SweepObservationBatchV1` (same availability rule as `SweepProjection`), chunked at 1,000 points, attested like the unleased batch.
- [x] 1.2 `Projectors.SweepObservation.committed/3`: publish the derived gauges through `DurablePublish` after commit, fresh primary deliveries only, message id `<event_id>:sweep-host-metrics:<n>`.
- [x] 1.3 `DurablePublish`: store a body that is not valid UTF-8 base64-encoded in the retry job (`body_base64`); the worker accepts either key.
- [x] 1.4 Tests: derived gauges per host and mode, chunking and message ids, non-primary deliveries publish nothing, binary-body retry round trip.
- [ ] 1.5 Verify on a deployment after rollout: an agent with only a leased group emits `sweep.host.available` rows for its targets (rows written after the rollout, for that agent).

## 2. Defect B: merged availability history (awaiting approval of design Decision 2 and the open questions)

- [ ] 2.1 History record and JetStream subject; EventWriter processor; CNPG and StarRocks tables (or the approved alternative).
- [ ] 2.2 Emit one record per transition from the `Transitions` outbox, including reconciliation changes, ungated, with a deterministic message id.
- [ ] 2.3 SRQL read path for a device's history over a time window.
- [ ] 2.4 Timeline: render merged history plus the current decision; unknown where nothing is recorded; remove the synthesized current-state fallback; agent selection shows that agent's probe history, labelled.
- [ ] 2.5 Tests for the record, the emitter, the reader and the bucket rules.
