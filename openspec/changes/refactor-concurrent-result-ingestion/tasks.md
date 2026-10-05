## 0. Approval and coordination (before implementation)

- [ ] 0.1 Obtain explicit user approval of the revised proposal; this PR contains documentation only and closes neither issue.
- [ ] 0.2 Confirm Agent B's PushStatus internal deadline, not-accepted mapping, supported version pairing, and rollout order on #5195.
- [ ] 0.3 Audit all result entry points, direct ingestion calls, shared writers (including raw Ecto), ordering keys, and current retained durable terminal outcomes on fresh staging.
- [x] 1.1 Add a supervised keyed queue (generalizing `EndpointInventoryIngestorQueue`): total and per-key item/byte bounds counting queued and in-flight work, one in-flight job per key, fair key interleaving, configurable workers on a dedicated `Task.Supervisor`, per-job timeout with task kill, optional per-key coalescing, and explicit rejection reasons.
- [x] 1.2 Emit `[:serviceradar, :result_ingestion, ...]` telemetry mirroring the admission-lane events, tagged by class; register metrics alongside `admission_lane_metrics/0`.
- [x] 1.3 Tests: per-key ordering, cross-key concurrency, each bound's rejection, coalescing, timeout and task exit, gauges back to zero.

## 1. Bounded keyed execution

- [ ] 1.1 Reuse/generalize existing admission workers with total/per-key item and byte credits covering queued, ingress-reserved, and in-flight work; bound mailboxes, task starts, and per-job lifetimes.
- [ ] 1.2 Give each result class independent capacity and supervisors; preserve per-key ordering, mapper interface/topology ordering, fairness, cancellation observation, and exactly-once credit release.
- [ ] 1.3 Validate global worker/memory/Repo budgets and reserve capacity for acknowledged lanes and other core services.
- [ ] 1.4 Load test-audit, then add behavioral tests for bounds, ordering, cross-key execution, worker exit, cancellation, coalescing eligibility, and safe restart/replay; register any new core test file in INTEGRATION_SOURCE_DISPOSITIONS.tsv.
- [x] 2.1 Route sweep, mapper interfaces, mapper topology, bumblebee, and non-retained plugin results to per-class queues, each behind a per-class flag that defaults on.
- [x] 2.2 Move service-state upserts into a batcher whose flush runs in a task; arm the timer only while items are pending and ignore ticks whose token does not match the armed timer (#5210 item 2).
- [x] 2.3 Remove database work from `handle_call({:results_update, _})`: any status still arriving by call is admitted to its class queue with the caller's reply reference.
- [ ] 2.4 Tests: a deliberately slow sweep ingestor does not delay another class's ingestion or an acknowledged result; the stale-tick race leaves one timer; no Repo query telemetry is attributed to the router process.

## 2. Dispatcher and inline-write removal

- [ ] 2.1 Move sweep, mapper, bumblebee, legacy plugin ingestion and service-state persistence onto bounded workers; retain existing destinations for types already handled off-path.
- [ ] 2.2 Make ResultsRouter call/cast/info callbacks perform classification/admission only, including transitive helpers, and use split-phase replies for acknowledged work.
- [ ] 2.3 Move workload identity, add-on status, and endpoint inventory preprocessing/persistence off StatusHandler callbacks; preserve ownership checks and coalesce only safe full snapshots.
- [ ] 2.4 Prove with deliberately blocked ingestors that other result classes can complete their acknowledgements; trace actual Repo query ownership and audit transitive Ash calls.
- [x] 3.1 Move workload identity snapshot persistence and add-on status ingestion to coalescing per-agent queues.
- [x] 3.2 Move endpoint inventory decode and service-state upsert out of the StatusHandler process into the endpoint inventory queue's task.
- [x] 3.3 Tests: a held workload identity write does not delay flow, endpoint inventory, or retained plugin admission; no Repo query telemetry is attributed to the StatusHandler process.

## 3. Retained contract and deadline

- [ ] 3.1 Verify the existing source/capability predicate with supported atom/string inputs and negative cases; enable retained admission by default.
- [ ] 3.2 Preserve durable-success/terminal-failure-marker acceptance, not-accepted on persistence failure, and exact agent pending-set/idempotent replay semantics.
- [ ] 3.3 Fit admission, execution, cancellation, and reply into Agent B's confirmed remaining deadline; reject invalid timeout configurations.
- [ ] 3.4 Implement bounded commit-confirming flag-off compatibility; prohibit inline fallbacks or duplicate owners during migration.
- [ ] 3.5 Exercise full lane, timeout, worker crash, late commit, unavailable worker, and repeated payload outcomes at the agent/gateway/core boundaries.

## 3a. Retained plugin lane by default (first PR)

- [ ] 3a.1 Confirm the `harden-flow-attribution-pipeline` task 9.1 preconditions (bounded two-way gateway forwarding and the updated agent deadline) are met in every supported release pairing.
- [x] 3a.2 Default `retained_plugin_admission_enabled` to true; keep it as a kill switch and document it.
- [x] 3a.3 Tests: default config admits capability-retained plugin results through the lane; a full lane NACKs immediately; the flag off restores the previous path.

## 4. Timer and sync admission (#5210 items 2 and 5)

- [ ] 4.1 Token ResultsRouter flush messages; invalidate before threshold flush/rearm, ignore stale ticks, arm only while pending, and bound both buffered and in-flight service-state batches.
- [ ] 4.2 Move actual batch writes into workers and preserve persistence-before-completion publication.
- [x] 4.3 Give SyncIngestorQueue bounded reply-bearing raw-payload admission, in-worker decoding, caller rejection handling, and run/chunk ordering.
- [x] 4.4 Prove rejected or unattributable chunks cannot activate partial snapshots; persist available incompleteness outside callbacks and preserve the existing population guard across restart/replay.
- [x] 4.5 Add stale-tick, queue-full-while-in-flight, byte-cap, malformed payload, interleaved incomplete/complete run, and no-retirement-on-overflow regressions.

## 5. JetStream telemetry

- [ ] 5.1 Emit bounded-cardinality queue depth/bytes, admission/execution latency, completion/rejection/timeout/crash/cancellation metrics as canonical envelopes through a bounded publisher and JetStream PubAck.
- [ ] 5.2 Verify metrics.core.result_ingestion permissions/routing, gauge/delta semantics, replay identity, outage buffering, drop accounting, and suppression of recursive publication failures.
- [ ] 5.3 Verify actual EventWriter persistence in the configured backend, supplementary local metrics, zero gauges after drain, and that telemetry outage does not delay ingestion acknowledgement.

## 6. Synthetic evidence, CI, and rollout

- [ ] 6.1 Implement a declared RBE/lab synthetic load harness comparing baseline and fix with identical invented inputs; vary concurrency/load, slow one class, and exercise overflow and worker failure.
- [ ] 6.2 Publish throughput, queue/high-water byte bounds, admitted/terminal/replay reconciliation, best-effort loss, and ack p50/p95/p99/max; p99 must be below 25 seconds and replies before 30 seconds, or the agreed stricter Agent B budget.
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
