## 0. Decisions and prerequisites
- [x] 0.1 Obtain the user's answers to design.md Q1-Q9 and record them as Resolved Questions (2026-11-04).
- [ ] 0.2 Archive `refactor-durable-alert-admission` (implemented by #5473) so the requirements this change removes exist in `openspec/specs/observability-signals`.
- [ ] 0.3 Confirm the anomaly-open eligibility fix (`RuleMatcher.event_candidate?/2`) has landed on `staging`; build on it as-is.
- [x] 0.4 Add the `observability-signals` delta for log-signal evaluation (resolved Q6).
- [ ] 0.5 Inventory every evaluation caller and every writer of rule state, alerts, history and notification jobs, including raw Ecto and dynamic dispatch, before changing any of them.

## 1. Golden traces and gates first
- [ ] 1.1 Capture golden effect traces from the current engine for every row of the design.md semantics table, using invented fixtures only (G5).
- [ ] 1.2 Add the synthetic fleet generator: invented device uids, `2001:db8::/32` addresses, embedded threshold crossings, per-key sequence numbers and an oracle of expected alerts.
- [ ] 1.3 Add G1 (router), G2 (owner), G3 (exactly-once fault injection) and G7 (small install footprint) as Bazel tests on RBE in BazelCI; give each an explicit failure branch.
- [ ] 1.4 Add G4 (fleet scale) and G6 (resharding under load) as an in-cluster disposable-namespace run, nightly and required before every release cut.

## 2. Rule index and router
- [ ] 2.1 Add immutable `stateful_alert_rule_revisions` and a `rule_set_version` published through the transactional outbox on every rule write.
- [ ] 2.2 Compile the per-signal index (subject trie, equality buckets, severity floors, catch-all) for event, metric and log stateful rules and for promotion rules; rebuild on change, not on a TTL; one `:persistent_term` write per change.
- [ ] 2.3 Route stored log records to `signal: :log` rules through the index (resolved Q6) and add a regression test with the seeded `burst_errors` rule.
- [ ] 2.4 Add rule validation warnings for catch-all rules and ungrouped rules on high-rate signals.
- [ ] 2.5 Stamp group key, metric violation increment, recovery-match flag and seasonal disposition into each candidate; compute the evaluation projection from the compiled field references.
- [ ] 2.6 Define `serviceradar.alerts.v1.Candidate` and the control message protobufs, with 128-bit candidate ids, the frozen `v1` hash over 1,024 virtual partitions and the 128-block layout.
- [ ] 2.7 Publish candidates asynchronously, await every PubAck, retry the unacknowledged subset in place with `+WPI` (including "no stream" refusals during a move), and never NAK for a publish failure.

## 3. Candidate streams and block ownership
- [ ] 3.1 Add `alert_stream_map` (generation, block-to-stream assignment, move journal) defaulting to one stream holding all 128 blocks; reconcile `ALERT_CANDIDATES_V1_*` and `ALERT_CANDIDATES_DLQ_V1` from the coordinator: R3, S2, Limits, DiscardNew, no MaxAge, minimal duplicate window, block wildcard subjects.
- [ ] 3.2 Add the new streams to every JetStream profile and the render-time budget check; add the `xlarge` profile with the 1 h candidate outage budget.
- [ ] 3.3 Add `alert_block_leases` with database-time compare-and-set, per-block epochs, one renewal statement per node, rendezvous placement over capable core replicas, an explicit pin option, rate-limited handoff and SIGTERM drain.
- [ ] 3.4 Run one owner process per node per stream on an ordered consumer filtered to its blocks, starting at the lowest block checkpoint and skipping per block; recreate it on gap or ownership change.
- [ ] 3.5 Implement the block move protocol (prepare, cut, rebind, drain and switch, reclaim) for candidate streams, journalled and resumable after coordinator failover, bounded by `max_concurrent_moves`.
- [ ] 3.6 Reconcile the stream map toward `candidate_stream_count` with contiguous, even block ranges; delete emptied streams after their purge floor passes.

## 4. Deterministic evaluation, effects and checkpoints
- [ ] 4.1 Refactor `StateMachine`, `AlertLifecycle` and their helpers so that decisions return effects as data and read no Repo, Ash or wall clock; add a test that enforces it.
- [ ] 4.2 Add fire keys (UUIDv5 incident, renotify ordinal, resolve, history, routing job) plus `alerts.fire_key` (unique) and `alerts.evaluation_position`; apply effects idempotently in one fenced transaction per batch, with DurablePublish for OCSF events.
- [ ] 4.3 Move incident counters into group state and write incident metadata once per commit, guarded by evaluation position.
- [ ] 4.4 Add incremental checkpoints: dirty group upserts and evictions in `stateful_alert_rule_states` (with `virtual_partition`), dedupe slices and `alert_block_checkpoints` in one fenced transaction; skip no-op checkpoints; purge each stream up to its lowest block checkpoint.
- [ ] 4.5 Add the 128-bit dedupe ring per block with persisted closed slices and a 10 min default horizon (resolved Q5).
- [ ] 4.6 Add crash-only recovery for transient failures, `alert_effect_failures` for permanent effect errors, and poison candidate quarantine to the DLQ with a recorded skipped disposition and redrive.
- [ ] 4.7 Add control inputs through the outbox: rule disable and delete markers, operator alert actions from web-ng and the API, stale-anomaly maintenance markers with live-series snapshots, and `alert_maintenance_receipts` per block that keep the synchronous count contract.
- [ ] 4.8 Make `LogPromotion` alerts idempotent by fire key and match promotion rules through the index.
- [ ] 4.9 Point the anomaly liveness check at the router and keep its persisted-alert wait.

## 5. Cutover and removal
- [ ] 5.1 Implement the cutover task: wait for no pre-cutover replica and no executing `alerts` job; convert snapshots and seed block checkpoints; import residual `alert_evaluation_work` and `lifecycle_pending_admissions` rows in their order onto the import subjects; write the import-end and cutover markers.
- [ ] 5.2 Make owners consume each block's import subject to its end marker before its live subject.
- [ ] 5.3 Add the post-cutover migration that refuses to run before the marker, drops the inbox, lane, receipt, ledger and pending-admission tables, and deletes pending jobs of the removed workers.
- [ ] 5.4 Delete `Inbox`, `Owner`, `EvaluationWorker`, `RecoveryWorker`, `Rollout`, `PeerReadiness`, `Completion`, `StatefulEvaluationLedger`, `MetricAlertAdmission`, `LifecycleAdmissionDrainWorker`, the pending-admission code in `AnalyticsSignals`, the `alerts` and `alert_recovery` queues, `alert_evaluation_limits`, and the Helm `SERVICERADAR_ALERT_EVALUATION_MODE` env with its helpers.
- [ ] 5.5 Add `AlertEvaluationSettings` (CNPG) with the small-install code defaults of design.md D11, and read every evaluation knob from it.
- [ ] 5.6 Release N+1: remove the cutover task and import subjects.

## 6. Ingestion at fleet scale
- [ ] 6.1 Split `events` into `LOGS_V1`, `EVENTS_V1` and `OTEL_V1` with block subjects from the shared layout; make them and `metrics` R3 and DiscardNew; default one stream per signal; migrate publishers and consumers with a drain of the old stream.
- [ ] 6.2 Add `telemetry_stream_count` per signal and apply the block move protocol to telemetry streams, gating each moved block on the target durable until the source durable's ack floor passes the cut.
- [ ] 6.3 Give EventWriter batchers per-signal concurrency, read batch shape and pull settings from runtime settings, and size `max_ack_pending` from the coalescing window.
- [ ] 6.4 Add the per-dataset warehouse load coalescer (rows, bytes, age) that acknowledges sources only after a successful load; run store and route in parallel and acknowledge after both.
- [ ] 6.5 Give alert-feeding durables unlimited `max_deliver` with BackOff; classify processor failures; copy permanent failures to `TELEMETRY_DLQ_V1` before `+TERM`.
- [ ] 6.6 Batch and pipeline the flowgger and trapd NATS outputs; add the bounded spool, refusal and spool-overflow counters, and UDP drop reporting (resolved Q8).
- [ ] 6.7 Move `ANALYTICS_PREDICTIONS`, the causal streams, `K8S_INVENTORY` and `TRIVY` to leased block ownership.

## 7. Observability and docs
- [ ] 7.1 Publish the stream, owner, router, move and collector metrics through JetStream with bounded labels; add the health transitions and the per-block and per-rule cost RPC.
- [ ] 7.2 Add capacity recommendations to health (split, merge, add capacity, with the setting value) and the opt-in `auto_reshard` mode gated on a placement dry run and the hysteresis window.
- [ ] 7.3 Add the web-ng alert pipeline diagnostics page.
- [ ] 7.4 Update `docs/docs/architecture.md` and `docs/docs/data-pipeline.md`; publish a capacity planning page with the target rates, per-node budgets, the CNPG-only ceiling and the 0.5-1 PB one-year StarRocks storage figure at 100,000 devices; add operator runbooks under `docs/` for resharding, DLQ redrive and a stuck block.

## 8. Proof
- [ ] 8.1 Pass G1-G3, G5 and G7 on every PR of this change; pass G4 at 50k with 30% headroom, then at 100k; pass G6 at the 100k rate.
- [ ] 8.2 Replace the `capacity.md` 1.4 estimates and the per-stream recommendation bounds with the G4 measurements.
- [ ] 8.3 Drive the cutover on a disposable environment from a populated inbox, and verify the alert set against the oracle and zero residual rows.
- [ ] 8.4 Label any live scenario that was not driven.
