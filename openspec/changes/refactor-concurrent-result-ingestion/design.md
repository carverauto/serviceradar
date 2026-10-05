## Context

The gateway forwards every status to `ServiceRadar.StatusHandler` on the core
coordinator node. Statuses that need a truthful acknowledgement (flow
attribution, endpoint inventory, capability-retained plugin results) arrive as
`GenServer.call`s with a 25-30 s deadline; everything else arrives as a cast.

What runs inside the two singletons today (staging, before this change):

| Process | Callback | Inline database work |
| --- | --- | --- |
| StatusHandler | `handle_call` fallback branch | blocks up to 30 s on a call into ResultsRouter |
| StatusHandler | `handle_cast`, `workload-identity` | `WorkloadIdentity.persist_snapshot` (decode + `Repo.query`, up to 50k rows) |
| StatusHandler | `handle_cast`, `service_name == "agent"` | `AddonStatusIngestor.ingest` (one `Ash.create` per add-on sidecar) |
| StatusHandler | endpoint inventory admission | payload decode and `ServiceStateRegistry.upsert_from_status` |
| ResultsRouter | `handle_call({:results_update, _})` | full ingest (`PluginResultIngestor`, ~30 Ash/Repo calls) plus a service-state upsert |
| ResultsRouter | `handle_info(:flush_results)` | up to 200 buffered statuses ingested serially (sweep, mapper, bumblebee, plugin), then `bulk_upsert_from_statuses` |

`RetainedPluginLane` and `FlowLane` (`ServiceRadar.Admission.Lane`) and
`EndpointInventoryIngestorQueue` already provide bounded, concurrent admission
with commit-confirmed replies. The retained-plugin lane is wired but gated off:
`retained_plugin_result_status?/1` returns true only when
`retained_plugin_admission_enabled` is set, and no deployment sets it. (GitHub
#5195 describes the predicate as hard-coded `false`; it is not, it is
configuration-gated with a `false` default.)

## Goals / Non-Goals

- Goals:
  - No Repo/Ash call runs inside a StatusHandler or ResultsRouter callback.
  - A slow ingest of one result class cannot delay acknowledgements or ingestion
    of another class.
  - Every queue between the gateway and an ingestor is bounded, and its depth and
    latency are observable.
  - The agent-facing retained-delivery contract is unchanged.
- Non-Goals:
  - Spreading ingestion across core nodes. The queues stay coordinator children;
    the concurrency gain is within the coordinator node, bounded by its Repo pool.
    The distributed design from the closed PR #4975 remains a possible follow-up.
  - Changing ingestor internals (per-item queries inside an ingestor are tracked
    separately, for example #5208).
  - Changing gateway forwarding, the StatusBuffer, or the Go agent.
  - Moving NATS publishing of add-on/plugin package telemetry out of StatusHandler.
    It does no database work; it is noted as a candidate for the same treatment.

## Decisions

- **Decision: enable `RetainedPluginLane` by default, keep the flag as a kill
  switch.** The lane, its bounds (two workers, 32 items, 64 MiB, 8 per agent,
  2 s queue wait, 20 s worker), and its durable-terminus reply already satisfy
  the `harden-flow-attribution-pipeline` requirements. The gate exists only to
  sequence rollout behind the bounded two-way gateway forwarding, which is in
  staging. This change completes that change's task 9.1 rather than redefining
  the lane. Turning the flag off restores today's inline path, so a rollback
  needs no code change.
  - Alternatives considered: a new lane for retained results (duplicates
    `Admission.Lane`); leaving the gate off and only fixing ResultsRouter (the
    retained path would still block both singletons for every plugin result).

- **Decision: ResultsRouter dispatches; per-class keyed queues ingest.** One
  supervised keyed-queue implementation (generalizing
  `EndpointInventoryIngestorQueue`) runs one instance per result class:

  | Class | Ordering key | Default workers | Overflow |
  | --- | --- | --- | --- |
  | sweep | `{agent_id, sweep group}` | 4 | reject newest, counted |
  | mapper interfaces / topology | `agent_id` | 2 | reject newest, counted |
  | bumblebee | `agent_id` | 2 | reject newest, counted |
  | legacy (non-retained) plugin results | `agent_id` | 2 | reject newest, counted |

  Each instance bounds pending plus in-flight items and bytes in total and per
  key, runs at most one job per key at a time (so a key's results apply in
  arrival order), interleaves keys fairly, and runs jobs on its own
  `Task.Supervisor` with a per-job timeout. The router process only classifies
  and admits. Classes that already route to `SyncIngestorQueue`, the endpoint
  inventory queue, or NATS (sync, census, mDNS, MTR) keep their destinations.
  - Overflow for these classes rejects the newest item because they arrive as
    gateway casts: the agent has already been acknowledged and nothing can retry
    it. Rejections are counted per class so loss is visible, matching the
    existing best-effort `StatusBuffer` contract.
  - Alternatives considered: a single `Task.Supervisor` with a global
    `max_children` (no per-key ordering, so an older sweep could overwrite a
    newer one); `:pg` worker pools across nodes (#4975, out of scope here).

- **Decision: StatusHandler cast-path writes coalesce per agent.** Workload
  identity snapshots and add-on status are periodic full-state reports; a newer
  pending report supersedes an older one for the same agent. They use the keyed
  queue with a coalescing mode: while an agent's job is pending, a newer report
  replaces it instead of queueing behind it. Endpoint inventory admission moves
  its decode and service-state upsert into the existing queue's task.

- **Decision: service-state batching moves into a task, with a tokened timer.**
  Service-state upserts keep today's coalescing (flush after 250 ms or 200
  items). The batch is handed to a task instead of being written in the router
  process. The timer is armed only when the first item is buffered, and each
  `:flush` message carries a reference that must match the armed timer, so a tick
  that fired before a cancel is ignored instead of starting a second chain
  (#5210 item 2). An idle router no longer wakes every 250 ms.

- **Decision: `SyncIngestorQueue` admits with a reply and decodes in the task.**
  `enqueue/1` becomes a bounded call (short timeout) returning `:ok` or
  `{:error, :sync_ingest_queue_full}`. The raw payload is held, and decoded only
  in the ingestion task, so the queue's mailbox and heap are bounded by the
  admitted bytes rather than by decoded maps. The bound counts work queued while
  a task is in flight (#5210 item 5). Callers are now queue workers, not the
  singleton, so the call cannot stall the router.
  - Sync results are grouped into runs (`{:sync_run, source_id, run_id}`).
    Snapshot activation already refuses a run whose collected distinct-row count
    does not match its declared population (`ArmisSourceSnapshot.activate/3`), so
    a dropped chunk cannot activate a partial snapshot today. What is missing is
    visibility: a run that loses a chunk to overflow is recorded as incomplete in
    its sync status, with the rejection reason, and the activation guard is kept
    and covered by a test on the overflow path.

- **Decision: telemetry follows the admission-lane convention.** Every queue
  emits `[:serviceradar, :result_ingestion, ...]` events mirroring
  `[:serviceradar, :admission_lane, ...]` (pending/in-flight count and bytes,
  admission wait, execution duration, completion result, rejection reason,
  timeout, crash), with bounded-cardinality `class` tags, exported by the
  existing `Telemetry.Metrics` reporter. These are process-health metrics of
  core itself, exported the same way as the lanes; none of them are written to
  the database.

## Risks / Trade-offs

- More concurrent writers against the coordinator's Repo pool -> per-class worker
  defaults are small and configurable, and the sum is checked against the pool
  size at boot.
- Concurrency can surface lock-order deadlocks that serial ingestion hid (device
  rows written by sweep and mapper) -> per-key ordering keeps one agent's work
  serial; ingestors that write the same device rows are reviewed for consistent
  lock order, and deadlock retries are measured during the canary.
- Rejecting cast-path results on overflow is new visible loss -> today the same
  overload shows up as unbounded mailbox growth and minutes of lag; rejections
  are counted per class, and the bounds are sized well above the observed steady
  state.
- Enabling the retained-plugin lane changes when a retained plugin result is
  NACKed -> the lane has been exercised in tests and canary under the existing
  change; the flag stays as a kill switch.

## Migration Plan

1. Land the keyed queue and telemetry with all classes still routed inline
   (no behavior change); verify gauges in a lab.
2. Route classes one at a time (sweep first, then mapper, bumblebee, legacy
   plugin, StatusHandler cast-path writes), each behind a per-class flag that
   defaults on in the release that ships it.
3. Enable `retained_plugin_admission_enabled` by default.
4. Bound `SyncIngestorQueue` admission and add the incomplete-run guard.
Rollback is per class: turn its flag off to restore inline processing.

## Open Questions

- Should the cast-path classes eventually become acknowledged (gateway call) so
  overflow can be retried by the agent instead of counted as loss? That is a
  gateway and agent contract change and is not proposed here.
- Should the queue-depth metrics also be published to JetStream so they are
  queryable in the platform, or is the existing Prometheus export enough?
