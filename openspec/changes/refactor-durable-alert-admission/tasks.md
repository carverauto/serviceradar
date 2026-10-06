## 1. Review and inventory
- [x] 1.1 Verify the remaining synchronous fan-out and startup paths on current staging.
- [x] 1.2 Check overlapping #5343, #5375, and #5349 before implementing duplicate work.
- [ ] 1.3 Obtain user approval for the admission/completion contract and design.
- [ ] 1.4 Enumerate every evaluation caller and every rule, snapshot, history, alert, and notification writer, including raw Ecto.

## 2. Durable admission
- [ ] 2.1 Add Ash resources, platform migrations, bounded admission, stable identities, and replay-safe receipt retention.
- [ ] 2.2 Integrate verified matching-rule routing and all-or-nothing admission.
- [ ] 2.3 Establish per-rule committed ordering, fenced claims, independent admission locks, and supervised bounded workers.

## 3. Evaluation and lifecycle
- [ ] 3.1 Evaluate from authoritative state and atomically persist every changed snapshot with completion.
- [ ] 3.2 Preserve incident identities, fire-once, cooldown, recovery, renotify, and seasonal disposition across replay.
- [ ] 3.3 Commit publication and notification work through the existing outbox contracts.
- [ ] 3.4 Migrate callers, preserve upstream rejection, update completion-dependent tests, and retain ordered maintenance counts.
- [ ] 3.5 Close the #4511 loss path and remove obsolete shard-start evaluation paths after caller migration.

## 4. Telemetry and proof
- [ ] 4.1 Publish bounded queue/age/latency/rejection metrics through JetStream and surface stopped/failed evaluation health.
- [ ] 4.2 Prove slow-owner isolation, per-rule ordering, overload rejection, restart recovery, and crash-point fire-once with synthetic owner tests.
- [ ] 4.3 Register new core tests and prove baseline regressions where feasible on RBE; never pin expected test counts.
- [ ] 4.4 Capture synthetic admission-versus-effect latency, throughput, rejections, bytes, and pool occupancy.
- [ ] 4.5 Drive no-mistakes and every latest-head PR check green, then merge the implementation PR with Closes #5197 and Closes #4511 only when fully satisfied.
- [ ] 4.6 Verify the capability-gated rollout and safe drain/rollback; label any unexecuted live scenarios explicitly.
