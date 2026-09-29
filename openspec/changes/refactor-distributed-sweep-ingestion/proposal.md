# Change: Distribute sweep result ingestion across the core cluster

## Why

Every sweep result chunk is ingested inside one process on one node. The
agent-gateway locates the coordinator's `StatusHandler`, which casts each chunk
to the coordinator-only `ResultsRouter`, and the router runs the whole
`SweepResultsIngestor` pass inline: execution bookkeeping, device lookup and
creation, per-host rows, per-agent availability, canonical availability,
composite-check refresh scheduling. The other core replicas do no result work
at all.

That process sustains a fixed rate (on the order of 13 ms per host, under 100
hosts per second) and spends most of its time waiting on the database. Once
the offered load passes that rate there is no second lane: the router mailbox
grows, every result type queues behind it, and results reach the database
later and later. A deployment that adds one large sweep group on a
five-minute interval, run by every agent in the partition, crosses the limit;
the observed symptom was results landing more than ten minutes after the
agent scanned, with the lag still growing, and a small five-minute group
waiting behind the large group's chunks so its devices looked unswept.

Spreading scans out so they do not overlap only moves the cliff. The fix is to
use the cluster: ingest sweep chunks in parallel on every core node, while
keeping the ordering the ingestor relies on.

## What Changes

- Add a coordinator-side `SweepJobs.Ingestion.Dispatcher`. `StatusHandler`
  hands asynchronous sweep result chunks to it instead of the singleton
  `ResultsRouter` mailbox. The dispatcher only derives a partition key and
  forwards; it never touches the database.
- Add a node-local `SweepJobs.Ingestion.Supervisor` on every core node that
  handles agent results. It starts a `:pg` scope and a fixed pool of
  `SweepJobs.Ingestion.Worker` processes (default 2 per node,
  `SWEEP_INGESTION_WORKERS_PER_NODE`). Workers join a `:pg` group; the
  dispatcher monitors membership, so workers on every node are used and nodes
  joining or leaving are picked up without configuration.
- Partition by `{agent_id, sweep_group_id}`. A key stays on its worker while it
  has chunks in flight, so chunks of one execution and consecutive executions
  of one group on one agent are ingested strictly in order. When a key is
  idle it is assigned to the least-loaded worker, so load follows work across
  nodes. Different groups and different agents ingest in parallel, so a small
  group no longer waits behind a large one.
- Workers run the existing `ResultsRouter` sweep path (the same ingestion and
  service-state publishing), so ingestion semantics do not change.
- With no registered workers (startup, or a node set that disables the pool),
  the dispatcher falls back to the current `ResultsRouter` path, so the change
  can never remove the ability to ingest.
- Make the ingestor's shared-row writes safe under concurrency: canonical
  availability, hysteresis and discovery-source updates on `ocsf_devices` lock
  their rows in `uid` order and retry once on a deadlock, and per-agent
  availability upserts are written in conflict-key order.
- Emit telemetry for dispatch, completion, fallback, per-key and per-worker
  in-flight depth, and chunks lost when a worker leaves with work in flight.

No breaking changes. No schema change. Agents and gateways are unchanged.

## Impact

- Affected specs: `sweep-jobs`.
- Affected code: `elixir/serviceradar_core/lib/serviceradar/status_handler.ex`,
  `results_router.ex`, `cluster/coordinator_children.ex`, `application.ex`,
  new `sweep_jobs/ingestion/*`, `sweep_jobs/sweep_results_ingestor.ex`,
  `serviceradar_core_elx/config/runtime.exs`.
- Operational: database connections used for sweep ingestion rise from one to
  at most `workers_per_node` per core node, drawn from each node's existing
  Repo pool.
