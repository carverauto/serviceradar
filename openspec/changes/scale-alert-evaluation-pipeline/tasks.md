## 0. Decisions and prerequisites
- [ ] 0.1 Obtain the user's answers to design.md Q1-Q9 and record them in design.md.
- [ ] 0.2 Archive `refactor-durable-alert-admission` (implemented by #5473) so the requirements this change removes exist in `openspec/specs/observability-signals`.
- [ ] 0.3 Confirm the anomaly-open eligibility fix (`RuleMatcher.event_candidate?/2`) has landed on `staging`; build on it as-is.
- [ ] 0.4 If Q6 is (a), add the `observability-signals` delta for log-signal evaluation and run `openspec validate --strict`.
- [ ] 0.5 Inventory every evaluation caller and every writer of rule state, alerts, history and notification jobs, including raw Ecto and dynamic dispatch, before changing any of them.

## 1. Golden traces and gates first
- [ ] 1.1 Capture golden effect traces from the current engine for every row of the design.md semantics table, using invented fixtures only (G5).
- [ ] 1.2 Add the synthetic fleet generator: invented device uids, `2001:db8::/32` addresses, embedded threshold crossings and an oracle of expected alerts.
- [ ] 1.3 Add G1 (router), G2 (partition) and G3 (exactly-once fault injection) as Bazel tests on RBE in BazelCI; give each an explicit failure branch.
- [ ] 1.4 Add the G4 fleet-scale action per Q7 and make it a required pre-release check.

## 2. Rule index and router
- [ ] 2.1 Add immutable `stateful_alert_rule_revisions` and a `rule_set_version` published through the transactional outbox on every rule write.
- [ ] 2.2 Compile the per-signal index (subject trie, equality buckets, severity floors, catch-all) for stateful and promotion rules; rebuild on change, not on a TTL; one `:persistent_term` write per change.
- [ ] 2.3 Add rule validation warnings for catch-all rules and ungrouped rules on high-rate signals.
- [ ] 2.4 Stamp group key, metric violation increment, recovery-match flag and seasonal disposition into each candidate; compute the evaluation projection from the compiled field references.
- [ ] 2.5 Define `serviceradar.alerts.v1.Candidate` and the control message protobufs, with 128-bit candidate ids.
- [ ] 2.6 Publish candidates asynchronously, await every PubAck, retry the unacknowledged subset in place with `+WPI`, and never NAK for a publish failure.

## 3. Candidate streams and partition ownership
- [ ] 3.1 Add `alert_partition_map` (default 64 logical partitions on 4 physical streams) and reconcile `ALERT_CANDIDATES_V1_S*` and `ALERT_CANDIDATES_DLQ_V1` from the coordinator: R3, S2, Limits, DiscardNew, per-subject limits, no MaxAge, minimal duplicate window.
- [ ] 3.2 Add the new streams to every JetStream profile and the render-time budget check; add the `xlarge` profile.
- [ ] 3.3 Add `alert_partition_leases` with database-time compare-and-set, epoch increment on acquire, rendezvous placement over capable core replicas, rate-limited handoff and SIGTERM drain.
- [ ] 3.4 Run each partition owner on an ordered consumer from checkpoint + 1, with gap detection.

## 4. Deterministic evaluation, effects and checkpoints
- [ ] 4.1 Refactor `StateMachine`, `AlertLifecycle` and their helpers so that decisions return effects as data and read no Repo, Ash or wall clock; add a test that enforces it.
- [ ] 4.2 Add fire keys (UUIDv5 incident, renotify ordinal, resolve, history, routing job) plus `alerts.fire_key` (unique) and `alerts.evaluation_seq`; apply effects idempotently in one fenced transaction per batch, with DurablePublish for OCSF events.
- [ ] 4.3 Move incident counters into group state and write incident metadata once per commit, guarded by sequence.
- [ ] 4.4 Add incremental checkpoints: dirty group upserts and evictions in `stateful_alert_rule_states` (with `partition` and `map_version`), dedupe slices, and the checkpoint row, in one fenced transaction; purge the subject behind it.
- [ ] 4.5 Add the 128-bit dedupe ring with persisted closed slices (horizon from Q5).
- [ ] 4.6 Add crash-only recovery for transient failures, `alert_effect_failures` for permanent effect errors, and poison candidate quarantine to the DLQ with a recorded skipped disposition and redrive.
- [ ] 4.7 Add control inputs through the outbox: rule disable and delete markers, operator alert actions from web-ng and the API, stale-anomaly maintenance markers with live-series snapshots, and `alert_maintenance_receipts` that keep the synchronous count contract.
- [ ] 4.8 Make `LogPromotion` alerts idempotent by fire key and match promotion rules through the index.
- [ ] 4.9 Point the anomaly liveness check at the router and keep its persisted-alert wait.

## 5. Cutover and removal
- [ ] 5.1 Implement the cutover task: wait for no pre-cutover replica and no executing `alerts` job; convert snapshots and seed checkpoints; import residual `alert_evaluation_work` and `lifecycle_pending_admissions` rows in their order onto the import subjects; write the import-end and cutover markers.
- [ ] 5.2 Make owners consume the import subject to its end marker before the live subject.
- [ ] 5.3 Add the post-cutover migration that refuses to run before the marker, drops the inbox, lane, receipt, ledger and pending-admission tables, and deletes pending jobs of the removed workers.
- [ ] 5.4 Delete `Inbox`, `Owner`, `EvaluationWorker`, `RecoveryWorker`, `Rollout`, `PeerReadiness`, `Completion`, `StatefulEvaluationLedger`, `MetricAlertAdmission`, `LifecycleAdmissionDrainWorker`, the pending-admission code in `AnalyticsSignals`, the `alerts` and `alert_recovery` queues, `alert_evaluation_limits`, and the Helm `SERVICERADAR_ALERT_EVALUATION_MODE` env with its helpers.
- [ ] 5.5 Add `AlertEvaluationSettings` (CNPG, code defaults) and read every evaluation knob from it.
- [ ] 5.6 Release N+1: remove the cutover task and import subjects.

## 6. Ingestion at fleet scale
- [ ] 6.1 Split `events` into `LOGS_V1`, `EVENTS_V1` and `OTEL_V1`; partition subjects with the shared versioned map; make them R3 and DiscardNew; migrate publishers and consumers with a drain of the old stream.
- [ ] 6.2 Give EventWriter batchers per-signal concurrency, read batch shape and pull settings from runtime settings, and size `max_ack_pending` from the coalescing window.
- [ ] 6.3 Add the per-dataset warehouse load coalescer (rows, bytes, age) that acknowledges sources only after a successful load; run store and route in parallel and acknowledge after both.
- [ ] 6.4 Give alert-feeding durables unlimited `max_deliver` with BackOff; classify processor failures; copy permanent failures to `TELEMETRY_DLQ_V1` before `+TERM`.
- [ ] 6.5 Batch and pipeline the flowgger and trapd NATS outputs; add the bounded spool, refusal and spool-overflow counters, and UDP drop reporting.
- [ ] 6.6 Move `ANALYTICS_PREDICTIONS`, the causal streams, `K8S_INVENTORY` and `TRIVY` to key-partitioned leased ownership.

## 7. Observability and docs
- [ ] 7.1 Publish the partition, router, stream and collector metrics through JetStream with bounded labels; add the health transitions and the per-rule cost RPC.
- [ ] 7.2 Add the web-ng alert pipeline diagnostics page.
- [ ] 7.3 Update `docs/docs/architecture.md` and `docs/docs/data-pipeline.md`; add operator runbooks under `docs/` for re-partitioning, DLQ redrive and a stuck partition.

## 8. Proof
- [ ] 8.1 Pass G1-G3 and G5 on every PR of this change, and pass G4 at 50k with 30% headroom, then at 100k.
- [ ] 8.2 Replace the `capacity.md` 1.4 estimates with the G4 measurements.
- [ ] 8.3 Drive the cutover on a disposable environment from a populated inbox, and verify the alert set against the oracle and zero residual rows.
- [ ] 8.4 Label any live scenario that was not driven.
