## 1. Distributed ingestion

- [x] 1.1 Add `SweepJobs.Ingestion.Worker`: joins the `:pg` group, ingests via the `ResultsRouter` sweep path, acknowledges every chunk, survives processor errors.
- [x] 1.2 Add `SweepJobs.Ingestion.Supervisor`: node-local `:pg` scope plus `workers_per_node` workers, `rest_for_one`.
- [x] 1.3 Add `SweepJobs.Ingestion.Dispatcher`: partition key `{agent_id, sweep_group_id}`, sticky while in flight, least-loaded when idle, `:pg.monitor/2` membership, fallback to `ResultsRouter`, lost-work accounting.
- [x] 1.4 Expose `ResultsRouter.process_sweep_status/1` for workers.
- [x] 1.5 Route asynchronous sweep results from `StatusHandler` to the dispatcher when it is running.
- [x] 1.6 Start the dispatcher as a coordinator child and the supervisor on every node with status handling enabled.
- [x] 1.7 Add `SWEEP_INGESTION_WORKERS_PER_NODE` to core-elx runtime configuration.
- [x] 1.8 Emit dispatch, completion, fallback, lost and dropped telemetry.

## 2. Concurrency safety

- [x] 2.1 Lock `ocsf_devices` rows in `uid` order for the available, hysteresis and discovery-source updates.
- [x] 2.2 Retry those statements once on `deadlock_detected`.
- [x] 2.3 Write per-agent availability upserts in conflict-key order.

## 3. Verification

- [x] 3.1 Dispatcher tests: ordering while in flight, least-loaded assignment, idle reassignment, worker loss, fallback.
- [x] 3.2 Worker tests: acknowledgement on success and on processor failure.
- [x] 3.3 `StatusHandler` test: asynchronous sweep results reach the dispatcher.
- [x] 3.4 Database test: concurrent ingestion of overlapping devices from two agents completes with correct per-agent availability.
- [x] 3.5 Register new test files in `INTEGRATION_SOURCE_DISPOSITIONS.tsv` and update Bazel selection counts.
