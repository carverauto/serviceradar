## 1. Shared keyed ingestion queue

- [ ] 1.1 Add a supervised keyed queue (generalizing `EndpointInventoryIngestorQueue`): total and per-key item/byte bounds counting queued and in-flight work, one in-flight job per key, fair key interleaving, configurable workers on a dedicated `Task.Supervisor`, per-job timeout with task kill, optional per-key coalescing, and explicit rejection reasons.
- [ ] 1.2 Emit `[:serviceradar, :result_ingestion, ...]` telemetry mirroring the admission-lane events, tagged by class; register metrics alongside `admission_lane_metrics/0`.
- [ ] 1.3 Tests: per-key ordering, cross-key concurrency, each bound's rejection, coalescing, timeout and task exit, gauges back to zero.

## 2. ResultsRouter as a dispatcher

- [ ] 2.1 Route sweep, mapper interfaces, mapper topology, bumblebee, and non-retained plugin results to per-class queues, each behind a per-class flag that defaults on.
- [ ] 2.2 Move service-state upserts into a batcher whose flush runs in a task; arm the timer only while items are pending and ignore ticks whose token does not match the armed timer (#5210 item 2).
- [ ] 2.3 Remove database work from `handle_call({:results_update, _})`: any status still arriving by call is admitted to its class queue with the caller's reply reference.
- [ ] 2.4 Tests: a deliberately slow sweep ingestor does not delay another class's ingestion or an acknowledged result; the stale-tick race leaves one timer; no Repo query telemetry is attributed to the router process.

## 3. StatusHandler cast-path writes

- [ ] 3.1 Move workload identity snapshot persistence and add-on status ingestion to coalescing per-agent queues.
- [ ] 3.2 Move endpoint inventory decode and service-state upsert out of the StatusHandler process into the endpoint inventory queue's task.
- [ ] 3.3 Tests: a held workload identity write does not delay flow, endpoint inventory, or retained plugin admission; no Repo query telemetry is attributed to the StatusHandler process.

## 4. Retained plugin lane by default

- [ ] 4.1 Confirm the `harden-flow-attribution-pipeline` task 9.1 preconditions (bounded two-way gateway forwarding and the updated agent deadline) are met in every supported release pairing.
- [ ] 4.2 Default `retained_plugin_admission_enabled` to true; keep it as a kill switch and document it.
- [ ] 4.3 Tests: default config admits capability-retained plugin results through the lane; a full lane NACKs immediately; the flag off restores the previous path.

## 5. Bounded sync ingestion admission

- [ ] 5.1 Make `SyncIngestorQueue.enqueue/1` a bounded call returning `:ok` or `{:error, :sync_ingest_queue_full}`; hold raw payloads and decode them in the ingestion task (#5210 item 5).
- [ ] 5.2 Mark a sync run incomplete when any of its chunks is rejected, and skip snapshot activation for it.
- [ ] 5.3 Tests: queue full while a task is in flight rejects and does not grow; malformed JSON is rejected by the task, not the queue; an overflowed run is not activated.

## 6. Rollout and evidence

- [ ] 6.1 Check the sum of per-class worker defaults against the coordinator Repo pool at boot and fail loudly when it exceeds it.
- [ ] 6.2 Load evidence from a synthetic fleet: ingestion throughput scales with worker counts, gateway acknowledgement p99 stays well under 30 s, and deadlock retries are recorded.
- [ ] 6.3 Close GitHub #5195 and #5210 when the change ships.
