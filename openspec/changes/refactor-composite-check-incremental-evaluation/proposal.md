# Change: Evaluate composite checks incrementally from a dirty set, not one job per swept device

## Why

Sweep result ingestion ends every batch by enqueuing one Oban
`CompositeChecks.RefreshWorker` job per device whose per-agent availability row
was upserted (`CompositeChecks.Refresh.enqueue_many/1`, called from
`SweepResultsIngestor`). The job then re-evaluates that single device: it pins
the identity fence, lists the device's result rows, and for every check loads
the check, its inputs, its rules, the availability rows, the metadata, the prior
result, and upserts the new one. Around fourteen statements per device per
check, before Oban's own fetch, complete and prune, and the trigger fires
whether or not anything about the device changed.

The 30-second `unique` window was meant to debounce, but sweeps run on
five-minute intervals, so it never collapses anything; it only adds the
uniqueness SELECT to every insert.

At the production scale this feature is meant for, a fleet where most of the
inventory is in composite-check scope (on the order of twenty thousand devices
on a five-minute sweep), that is roughly seventy job inserts per second inside
the ingestion hot path, on the order of a thousand statements per second of
re-evaluation that almost always reproduces the previous verdict, and twenty
thousand `oban_jobs` rows inserted, completed and pruned every cycle. It is the
largest per-host cost in sweep ingestion and the reason ingestion falls behind
the offered load; the periodic pass, which already resolves inputs per page with
bounded queries, then repeats the same work on its own schedule.

The periodic pass has the right shape and the wrong write side: `persist_page`
issues one Ash upsert per device, and a check that writes canonical
availability issues a get and an update per device on top. A pass over twenty
thousand devices is about sixty thousand statements when it could be under a
hundred.

A composite verdict is derived state: a pure function of a handful of rows.
Derived state at this scale is recomputed over a dirty set in batches or on
read. It is never recomputed one job per input change.

## What Changes

- Remove the composite-check refresh hook from sweep result ingestion.
  `SweepResultsIngestor` writes availability rows and stops; it has no
  knowledge of composite checks. `CompositeChecks.Refresh` and
  `RefreshWorker` are removed.
- Add an incremental evaluation pass per enabled check. Each check keeps a
  high-water mark of the last evaluation. The incremental pass selects, in one
  bounded query, the in-scope devices whose input rows changed after that mark
  (per-agent availability for the check's vantage-point agents, device
  metadata for metadata inputs) and evaluates only those devices through the
  existing paged `Evaluation.evaluate_devices/5`. It runs on a short interval
  (tens of seconds) so verdicts stay as fresh as the reactive path made them.
- Keep the periodic full pass on `evaluation_interval_seconds` for the two
  transitions that produce no row change: an input aging past `max_age` and a
  device entering or leaving scope. This is unchanged and remains required.
- Make the write side set-based. `persist_page` writes each page's results with
  one multi-row upsert; canonical availability is written with one set-based
  update per page. Transitions are still computed in memory against
  `load_existing`, so verdict events are unchanged.
- Oban keeps exactly one job kind for composite checks: the per-check
  scheduler (`EvaluationWorker`), which now runs both the incremental and the
  full pass.

## Value and Tradeoff

- Expected gain: sweep ingestion loses its largest per-host cost with no new
  processes, no cluster-wide dispatcher and no message queue; the `oban_jobs`
  table stops churning tens of thousands of rows per sweep cycle; a full
  composite pass becomes cheap enough to run more often than it does today.
- Freshness: a verdict follows an input change within one incremental interval
  instead of within the Oban debounce window. Both are tens of seconds.
- Risk: the dirty query must be indexed. `device_agent_availability.updated_at`
  moves on every upsert and needs an index; `ocsf_devices.updated_at` is an Ash
  `update_timestamp`, so metadata writes through Ash move it, but a raw write
  path that does not is picked up by the full pass only. The design records
  the audit.
- Decision point: if the identity fence cannot be preserved without per-device
  jobs, keep a single job per page carrying the dirty uids rather than one per
  device. The design shows the fence is applied at evaluation time by the
  incremental pass the same way the full pass applies it, so this fallback is
  not expected to be needed.

## Relationship to other changes

- Supersedes the approach in `refactor-distributed-sweep-ingestion` (PR
  carverauto/serviceradar#4975). That change parallelised ingestion across
  core nodes around this cost instead of removing it; distributing an I/O-bound
  loop over more nodes does not change the number of statements per host. Its
  `SweepResultsIngestor` hardening (ordered `FOR UPDATE` selection, sorted
  upserts, deadlock retry) is independent of this change and can land on its
  own.
- Modifies requirements introduced by `add-composite-service-checks`, which is
  implemented and awaiting archive. This change's delta assumes that change's
  `composite-checks` spec is the base; archive it first.

## Tracking

- Issue: carverauto/serviceradar#4978

## Impact

- Affected specs: `composite-checks`, `sweep-jobs`.
- Affected code: `elixir/serviceradar_core/lib/serviceradar/composite_checks/`
  (`refresh.ex`, `refresh_worker.ex`, `evaluation.ex`, `evaluation_worker.ex`,
  `scope.ex`, `composite_check.ex`),
  `elixir/serviceradar_core/lib/serviceradar/sweep_jobs/sweep_results_ingestor.ex`,
  a migration adding the evaluation high-water mark and the
  `device_agent_availability(updated_at)` index, and the tests under
  `elixir/serviceradar_core/test/serviceradar/composite_checks/`.
- Operational: no configuration change. Oban `monitoring` queue load drops from
  one job per swept device to one job per enabled check per interval.
