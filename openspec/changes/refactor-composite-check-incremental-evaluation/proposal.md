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
- Add an incremental evaluation pass per enabled check. Each check keeps
  `last_incremental_at`, the database clock (`SELECT now()`) taken at the
  start of the last successful pass, before its dirty read. The incremental
  pass selects, in bounded queries, the in-scope devices whose input rows
  changed after that mark: per-agent availability `updated_at` for the check's
  vantage-point agents, and for metadata inputs the provenance timestamp
  `:device_metadata` resolves
  (`metadata['__fact_provenance'][path]['updated_at']` on each configured
  path). It never reads `ocsf_devices.modified_time`. It evaluates only those
  devices through the existing paged `Evaluation.evaluate_devices/5`, following
  the canonical uid for the page in one query and skipping a uid that does not
  resolve to a live device. It runs on a short interval (tens of seconds) so
  verdicts stay as fresh as the reactive path made them.
- Keep the periodic full pass on `evaluation_interval_seconds`, scheduled from
  the existing `composite_checks.last_evaluated_at` (advanced only by a
  successful full pass). It covers the two transitions that produce no row
  change: an input aging past `max_age` and a device entering or leaving scope.
  It also covers metadata keys that have no provenance timestamp. This pass
  remains required.
- Make the write side set-based. `persist_page` writes each page's results with
  one multi-row upsert and never writes a result for a merged-away uid.
  Canonical availability is a bulk form of `Device.set_availability`
  (`is_available` only: one update for healthy uids, one for down uids,
  skipping `:degraded` and `:unknown`). Transitions are still computed in
  memory against `load_existing`, so verdict events are unchanged.
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
- Risk: the availability dirty query must be indexed.
  `device_agent_availability.updated_at` is stamped with `now()` inside the
  ingestor's INSERT, so it moves when an observation commits and cannot precede
  a pass mark taken before that commit. Metadata dirtiness is the fact
  provenance timestamp on the check's configured paths. Sweep status writes and
  `set_availability` do not write that provenance, so they do not dirty a
  device; a metadata key with no provenance is covered by the full pass only.
- Decision point: the pass follows the canonical uid at evaluation time (one
  batched `Resolver.follow_canonical_device_id` query per page), skips a uid
  that does not resolve to a live device, and writes no result for a
  merged-away uid. That needs no per-device job and no per-page fallback job.

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
  a migration adding `last_incremental_at` (the full-pass clock
  `last_evaluated_at` already exists) and the
  `device_agent_availability(agent_id, updated_at)` index, the ingestor
  stamping that `updated_at` with `now()` inside the INSERT, and the tests under
  `elixir/serviceradar_core/test/serviceradar/composite_checks/`.
- Operational: no configuration change. Oban `monitoring` queue load drops from
  one job per swept device to one job per enabled check per interval.
