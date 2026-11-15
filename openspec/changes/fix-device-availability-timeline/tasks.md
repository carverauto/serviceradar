## 1. Defect A: leased sweeps produce per-host gauges (bug fix)

- [x] 1.1 `ServiceRadar.Edge.SweepHostMetrics`: derive the per-host gauges of a `SweepObservationBatchV1` (same availability rule as `SweepProjection`), chunked at 1,000 points, attested like the unleased batch.
- [x] 1.2 `Projectors.SweepObservation.committed/3`: publish the derived gauges through `DurablePublish` after commit, fresh primary deliveries only, message id `<event_id>:sweep-host-metrics:<n>`.
- [x] 1.3 `DurablePublish`: store a body that is not valid UTF-8 base64-encoded in the retry job (`body_base64`); the worker accepts either key.
- [x] 1.4 Tests: derived gauges per host and mode, chunking and message ids, non-primary deliveries publish nothing, binary-body retry round trip.
- [x] 1.6 No loss window: `platform.sweep_host_gauge_pending` marker recorded in the ledger transaction, cleared by the committed publish; `SweepHostGaugeSweeper` republishes markers older than 120 s, 50 per pass, every minute.
- [x] 1.7 Tests: a crash between commit and publish leaves the marker, and the sweeper republishes the gauges once (DB, through `EdgeRecord.ingest/4`'s `:transaction_result` hook); a message neither published nor queued is an error that keeps the marker.
- [ ] 1.5 Verify on a deployment after rollout: an agent with only a leased group emits `sweep.host.available` rows for its targets (rows written after the rollout, for that agent).

## 2. Defect B: merged availability history (approved 2026-11-14: storage option 1, any-down bucket rule with minutes-down tooltip, authoritative mode only; follow-up PR)

- [x] 2.1 History record and JetStream subject; EventWriter processor; CNPG hypertable and StarRocks table (StarRocks only when enabled).
- [x] 2.2 Emit one record per transition from the `Transitions` outbox, including reconciliation changes, ungated, with a deterministic message id.
- [x] 2.3 SRQL read path for a device's history over a time window.
- [x] 2.4 Timeline: render merged history plus the current decision; unknown where nothing is recorded; remove the synthesized current-state fallback; offline buckets show minutes down; agent selection shows that agent's probe history, labelled; `legacy`/`shadow` modes keep the probe timeline, labelled as probe history.
- [x] 2.5 Tests for the record, the emitter, the reader and the bucket rules.
- [ ] 2.6 Verify on a deployment after rollout: a device's history rows exist (StarRocks when enabled, CNPG otherwise) after a merged state change, and the timeline matches the badge.
