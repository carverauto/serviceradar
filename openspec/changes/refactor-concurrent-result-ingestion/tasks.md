## 0. Approval and coordination (before implementation)

- [x] 0.1 Obtain explicit user approval of the revised proposal; this PR contains documentation only and closes neither issue.
- [x] 0.2 Confirm Agent B's PushStatus internal deadline, not-accepted mapping, supported version pairing, and rollout order on #5195.
- [x] 0.3 Audit all result entry points, direct ingestion calls, shared writers (including raw Ecto), ordering keys, and current retained durable terminal outcomes on fresh staging.

## 1. Bounded keyed execution

- [x] 1.1 Reuse/generalize existing admission workers with total/per-key item and byte credits covering queued, ingress-reserved, and in-flight work; bound mailboxes, task starts, and per-job lifetimes.
- [x] 1.2 Give each result class independent capacity and supervisors; preserve per-key ordering, mapper interface/topology ordering, fairness, cancellation observation, and exactly-once credit release.
- [x] 1.3 Validate global worker/memory/Repo budgets and reserve capacity for acknowledged lanes and other core services.
- [x] 1.4 Load test-audit, then add behavioral tests for bounds, ordering, cross-key execution, worker exit, cancellation, coalescing eligibility, and safe restart/replay; register any new core test file in INTEGRATION_SOURCE_DISPOSITIONS.tsv.

## 2. Dispatcher and inline-write removal

- [x] 2.1 Move sweep, mapper, bumblebee, legacy plugin ingestion and service-state persistence onto bounded workers; retain existing destinations for types already handled off-path.
- [x] 2.2 Make ResultsRouter call/cast/info callbacks perform classification/admission only, including transitive helpers, and use split-phase replies for acknowledged work.
- [x] 2.3 Move workload identity, add-on status, and endpoint inventory preprocessing/persistence off StatusHandler callbacks; preserve ownership checks and coalesce only safe full snapshots.
- [ ] 2.4 Prove with deliberately blocked ingestors that other result classes can complete their acknowledgements; trace actual Repo query ownership and audit transitive Ash calls.

## 3. Retained contract and deadline

- [x] 3.1 Verify the existing source/capability predicate with supported atom/string inputs and negative cases; enable retained admission by default.
- [x] 3.2 Preserve durable-success/terminal-failure-marker acceptance, not-accepted on persistence failure, and exact agent pending-set/idempotent replay semantics.
- [x] 3.3 Fit admission, execution, cancellation, and reply into Agent B's confirmed remaining deadline; reject invalid timeout configurations.
- [x] 3.4 Implement bounded commit-confirming flag-off compatibility; prohibit inline fallbacks or duplicate owners during migration.
- [ ] 3.5 Exercise full lane, timeout, worker crash, late commit, unavailable worker, and repeated payload outcomes at the agent/gateway/core boundaries.

## 3a. Retained plugin lane by default (first PR)

- [ ] 3a.1 Confirm the `harden-flow-attribution-pipeline` task 9.1 preconditions (bounded two-way gateway forwarding and the updated agent deadline) are met in every supported release pairing.
- [x] 3a.2 Default `retained_plugin_admission_enabled` to true; keep it as a kill switch and document it.
- [x] 3a.3 Tests: default config admits capability-retained plugin results through the lane; a full lane NACKs immediately; the flag off restores the previous path.

## 4. Timer and sync admission (#5210 items 2 and 5)

- [x] 4.1 Token ResultsRouter flush messages; invalidate before threshold flush/rearm, ignore stale ticks, arm only while pending, and bound both buffered and in-flight service-state batches.
- [x] 4.2 Move actual batch writes into workers and preserve persistence-before-completion publication.
- [x] 4.3 Give SyncIngestorQueue bounded reply-bearing raw-payload admission, in-worker decoding, caller rejection handling, and run/chunk ordering.
- [ ] 4.4 Prove rejected or unattributable chunks cannot activate partial snapshots; persist available incompleteness outside callbacks and preserve the existing population guard across restart/replay.
- [x] 4.5 Add stale-tick, queue-full-while-in-flight, byte-cap, malformed payload, interleaved incomplete/complete run, and no-retirement-on-overflow regressions.

## 5. JetStream telemetry

- [x] 5.1 Emit bounded-cardinality queue depth/bytes, admission/execution latency, completion/rejection/timeout/crash/cancellation metrics as canonical envelopes through a bounded publisher and JetStream PubAck.
- [ ] 5.2 Verify metrics.core.result_ingestion permissions/routing, gauge/delta semantics, replay identity, outage buffering, drop accounting, and suppression of recursive publication failures.
- [ ] 5.3 Verify actual EventWriter persistence in the configured backend, supplementary local metrics, zero gauges after drain, and that telemetry outage does not delay ingestion acknowledgement.

## 6. Synthetic evidence, CI, and rollout

- [ ] 6.1 Implement a declared RBE/lab synthetic load harness comparing baseline and fix with identical invented inputs; vary concurrency/load, slow one class, and exercise overflow and worker failure.
- [ ] 6.2 Publish throughput, queue/high-water byte bounds, admitted/terminal/replay reconciliation, best-effort loss, and ack p50/p95/p99/max; p99 must be below 15 seconds and replies before 30 seconds, or the agreed stricter Agent B budget.
- [ ] 6.3 Run no-mistakes without --yes and require every PR BazelCI/native check green before implementation merge; report untested live scenarios explicitly.
- [ ] 6.4 Apply the coordinated gateway-first compatible rollout; verify canary metrics and safe bounded rollback without overlapping writers.
- [ ] 6.5 Close #5195 and #5210 only when their implementation and evidence requirements land; no count pins or captured live fixtures.
- [ ] 6.6 Check the sum of per-class worker defaults against the coordinator Repo pool at boot and fail loudly when it exceeds it.
- [ ] 6.7 Load evidence from a synthetic fleet: ingestion throughput scales with worker counts, gateway acknowledgement p99 stays well under 30 s, and deadlock retries are recorded.
- [ ] 6.8 Close GitHub #5195 and #5210 when the change ships.

## 7. Lane metrics publication and visibility (last PR)

- [ ] 7.1 Add a periodic aggregator that publishes one `serviceradar.metric.v1` MetricBatch per interval on `metrics.ingestion_lanes` via `ServiceRadar.NATS.JetStreamPublish`, following `ServiceRadar.FlowAttribution.PassMetrics`; log and ignore publish failures.
- [ ] 7.2 Test that the published envelope is accepted and persisted by the EventWriter `Metrics` processor, that a publish failure leaves ingestion unaffected, and that many admissions in one interval yield one batch.
- [ ] 7.3 Register the lane `:telemetry` events as `Telemetry.Metrics` in core-elx's metrics (depth last_value; admitted, rejected, NACK, incomplete-run counters; lane/class tags only) and add Grafana panels to the chart's ingestion dashboards, validated as parsed dashboard JSON.
- [ ] 7.4 Seed a ServiceRadar dashboard in web-ng charting the persisted lane metrics from `timeseries_metrics` via SRQL (depth, reject and NACK rates).
- [ ] 7.5 Add an Ingestion card and table to Settings -> Cluster Status fed by a lane-stats call on the page's existing refresh timer (no query or RPC in the disconnected mount), with LiveView tests for lane values and the unavailable state.

## Evidence status

Checked implementation items describe code and authored coverage, not a claim
that the changed tests have passed. Verification/evidence items remain open
until their actual RBE or rollout proof exists. The per-key baseline regression
failed at the intended scheduling assertion in invocation
296e5416-07fc-4c3e-95ae-e730be35ccf5; that run also had a wrapper-default mismatch.
The fixed tree has not been compiled locally. PR BazelCI is the compiled gate.
The synthetic burst harness prints RESULT_INGESTION_SYNTHETIC_LOAD; measurements
and the identical-input baseline comparison are still pending.

The corrected identical-input dispatcher baseline passed in invocation
95dcebf7-42b3-4f35-b25b-28074e46bea5 on staging 8c9c17fa3d. Its synthetic
48/192-offer results are recorded in docs/result-ingestion-operations.md.
The earlier load invocation e3acabbe-71e9-41fa-989f-469a48b0b212 is excluded
because its harness omitted the old flow reply-lease supervisor. Fixed load,
durable-store, and live rollout evidence remain pending.

The worker-tree downtime regression failed at the intended public reservation
boundary in RBE invocation afb86701-0c97-4f94-aab5-c16bbbfa4bc6 on published
head 6c538e085cbc55962257aefd3222aaa1c0767675 with the regression added.
StatusHandler raised an unknown-registry ArgumentError instead of rejecting
admission. Fixed-head rejection, dispatcher survival, and recovery proof remain
pending PR BazelCI.

The default per-agent byte-credit regressions failed at their intended public
admission boundaries in RBE invocation
b90f71c2-2b63-4108-818d-4f8e4a8f794e on published head
6c538e085cbc55962257aefd3222aaa1c0767675 with only the test patch applied.
Both remote attempts failed the four sweep, sweep reservation, flow, and
retained-plugin assertions: the pre-fix defaults accepted excess work from
one agent instead of returning per_agent_byte_full. Fixed-head fairness and
remaining durable-store evidence are still pending PR BazelCI.
