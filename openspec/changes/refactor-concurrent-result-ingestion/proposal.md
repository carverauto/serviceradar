# Change: Stop serializing result ingestion through the StatusHandler and ResultsRouter singletons

## Why
Every status and result that reaches core is handled by two coordinator-only
singleton GenServers, `ServiceRadar.StatusHandler` and `ServiceRadar.ResultsRouter`,
and both run database work inside their own callbacks. Result ingestion for the
whole fleet is therefore capped at one database stream on one node, and the
synchronous acknowledgements that agents wait on queue behind unrelated writes
until they hit the 30-second gateway call timeout (GitHub #5195). Two related
defects live in the same processes: the ResultsRouter flush timer can multiply
into extra 250 ms chains, and `SyncIngestorQueue` decodes JSON in its mailbox and
grows without bound while an ingestion task is in flight (GitHub #5210 items 2
and 5).

## What Changes
- **Retained plugin results are admitted by `RetainedPluginLane` by default.**
  The lane, its bounds, and its commit-confirmed reply contract already exist
  (`harden-flow-attribution-pipeline`); it is held behind
  `retained_plugin_admission_enabled`, which defaults to `false`, so today every
  capability-retained plugin result is ingested by a synchronous
  StatusHandler -> ResultsRouter call chain. This change turns the gate on by
  default and keeps it as a kill switch that restores today's path.
  **BREAKING (ack semantics):** a retained plugin result that the lane cannot
  admit is now negatively acknowledged immediately
  with an explicit admission reason (`count_full`, `per_agent_full`, ...)
  instead of waiting in the singleton mailbox until it commits or times out.
  The agent-facing retained-delivery contract (`received: false` keeps the exact
  pending set) is unchanged.
- **ResultsRouter becomes a dispatcher that does no database work.** Each result
  class it handles today (sweep, mapper interfaces, mapper topology, bumblebee,
  legacy plugin results, service-state updates) is handed to a bounded, supervised
  per-class ingestion queue that runs the existing ingestor in a task. Work is
  ordered only where a class needs it, by a per-class key (for example sweep
  results per agent and sweep group), and different keys run concurrently up to
  the class's worker bound.
- **StatusHandler's inline cast-path writes move off the singleton.** Workload
  identity snapshot persistence, add-on status ingestion, and the endpoint
  inventory admission step that currently decodes and upserts service state
  inside StatusHandler all run in bounded queues instead. Snapshot-style inputs
  (workload identity, add-on status) coalesce to the newest pending item per
  agent.
- **Service-state upserts are batched outside the router process.** The batching
  that today's 250 ms flush provides is kept, but the flush runs in a task, the
  timer is only armed while work is pending, and each tick carries a token so a
  stale tick can no longer start a second timer chain (#5210 item 2).
- **`SyncIngestorQueue` admission is bounded.** Payloads are decoded in the
  ingestion task, not the queue's mailbox; admission replies and rejects work
  beyond a configured count/byte bound, including while a task is in flight
  (#5210 item 5). A sync run that loses a chunk to overflow is recorded as
  incomplete, and the existing population check keeps it from being activated
  from partial data.
- **Backlog is observable before acks time out.** Each new queue reports pending
  and in-flight depth and bytes, admission wait, execution duration, and
  rejections, using the existing admission-lane telemetry conventions.

## Impact
- Affected specs: `edge-architecture` (ADDED requirements for singleton-free
  result routing, per-class bounded ingestion, and retained-plugin lane default),
  `ingestion-routing` (ADDED requirement for bounded sync ingestion admission).
- Depends on: `harden-flow-attribution-pipeline` (owns the lane requirements and
  task 9.1, the rollout order for enabling retained-plugin routing). Enabling the
  lane by default is that task's last step made permanent.
- Affected code: `elixir/serviceradar_core/lib/serviceradar/status_handler.ex`,
  `results_router.ex`, `admission/*`, `inventory/sync_ingestor_queue.ex`,
  `inventory/endpoint_inventory_ingestor_queue.ex`,
  `cluster/coordinator_children.ex`, `workload_identity.ex`,
  `plugins/addon_status_ingestor.ex`, `service_state_registry/*`; gateway status
  forwarding is unchanged apart from the admission reasons it now receives.
- Closes on landing: GitHub #5195 and #5210 (whose remaining items 2 and 5 are
  folded in here).
