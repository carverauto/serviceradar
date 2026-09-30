# Design: Incremental composite-check evaluation

## Context

Three code paths evaluate composite checks today:

| Path | Trigger | Reads per device | Writes per device |
| --- | --- | --- | --- |
| `RefreshWorker` (per device) | Oban job from sweep ingestion | ~9 per check | 1 Ash upsert, plus transition |
| `EvaluationWorker` full pass | `evaluation_interval_seconds` | 3 per 1,000-device page | 1 Ash upsert, plus 2 for canonical availability |
| Authoring preview | UI | n/a | none |

All three call the pure `Evaluator.verdict/2`, which this change keeps. The
problem is entirely in how devices reach it and how results leave it.

The reactive path exists to make a verdict follow an availability change
faster than the full pass would. That goal stands. The mechanism, one Oban job
per swept device, does not survive a fleet where most devices are in scope.

## Goals

- Sweep ingestion issues zero statements on behalf of composite checks.
- A verdict follows an input change within a bounded, short interval.
- Full and incremental passes share one evaluation and one persistence path.
- Statement count per pass is proportional to pages, not devices.

## Non-goals

- Changing the decision table, inputs, resolvers or verdict events.
- Recomputing verdicts on read. The result rows remain the query surface for
  rollups and dashboards.
- Removing the full pass. Its moduledoc explains why it cannot be replaced by
  any event or dirty-set mechanism; that reasoning is unchanged.

## Decisions

### 1. Remove the hook from ingestion rather than batching it

The obvious smaller fix is one Oban job per chunk carrying the uid list. It
removes the per-device insert but keeps the coupling: the ingestor still knows
about composite checks, and each job still evaluates devices that did not
change. The dirty-set query below makes the hook unnecessary, so the hook goes.
`CompositeChecks.Refresh` and `RefreshWorker` are deleted, not deprecated.

### 2. Dirty set from row timestamps, not from a dirty table

Each check records `last_incremental_at` (the start time of its last completed
incremental or full pass). The incremental pass computes the dirty set as:

- devices with a `device_agent_availability` row for one of the check's
  vantage-point agents whose `updated_at > last_incremental_at`;
- when the check has a metadata input, devices whose `ocsf_devices.updated_at >
  last_incremental_at`;
- intersected with the check's scope.

`device_agent_availability.updated_at` is set on every upsert by the ingestor
(`EXCLUDED.updated_at` in the conflict update), so it moves exactly when an
observation is accepted. It has no index today; the migration adds
`(agent_id, updated_at)`. `ocsf_devices.updated_at` is an Ash
`update_timestamp`, so writes through Ash actions move it. Raw `update_all`
paths that skip it (the ingestor's own availability and discovery-source
updates are examples) leave a metadata change for the full pass, which is
acceptable: those paths do not write the metadata a `:device_metadata` input
reads.

Alternative rejected: a `composite_check_dirty_devices` table the ingestor
inserts into. It reintroduces a write into ingestion, needs its own pruning,
and duplicates information the availability row already carries.

Alternative rejected: an availability-transition event on JetStream consumed by
an EventWriter processor. Sweep ingestion already computes transitions for
`AvailabilityEvents.emit` when a group opts in, and EventWriter processors are
handed batches, so this is a coherent design. It adds a stream, a processor,
and a second trigger path that has to be kept consistent with the full pass,
for the same freshness the timestamp query gives with nothing new to operate.
If a future consumer needs availability transitions as events for another
reason, composite checks can subscribe then.

### 3. Scope intersection

The scope is an SRQL query and cannot be joined in SQL. The incremental pass
therefore streams the dirty uids in pages (the same `page_limit` as the full
pass) and filters each page through `Scope.contains?/2`, a new function that
runs the scope query with an added `uid in (...)` restriction for one page.
One SRQL call per page, the same bound the full pass has.

The dirty set on a steady fleet is small (devices whose observation was
accepted since the last pass, which for a five-minute sweep and a thirty-second
incremental interval is roughly one tenth of the fleet, and only those whose
row actually changed if the ingestor's `checked_at >=` guard rejected the
rest). Where a whole sweep lands inside one interval the dirty set approaches
the scope and the incremental pass costs what one full pass costs, which is
the ceiling, not a regression.

### 4. Set-based persistence

`persist_page/4` computes transitions in memory against `load_existing/2`
exactly as it does now, then writes the page with one
`Repo.insert_all(DeviceCompositeCheckResult, rows, on_conflict: ...,
conflict_target: [:device_uid, :check_id])`. `changed_at` is carried per row.
The Ash `:upsert` action stays for the authoring preview and tests that use it
but is no longer on the evaluation path.

Canonical availability for a check with `write_canonical_availability` becomes
one `update_all` per page over `ocsf_devices` for the healthy uids and one for
the down uids, replacing the per-device get and update. Both run through the
same `Device` policy actor the per-device path used, via a bulk Ash action or a
raw query behind the existing `set_availability` semantics, whichever the
implementer finds already exists for the sweep path (the ingestor's
`update_device_statuses_available/3` is the precedent).

### 5. One scheduler

`EvaluationWorker` runs the incremental pass every `incremental_interval`
(a module attribute, default thirty seconds, not operator-facing) and the full
pass when `evaluation_interval_seconds` has elapsed since the last full pass.
A full pass also advances `last_incremental_at`, so no device is evaluated
twice for one change. The Oban `unique` on `check_id` is unchanged.

A pass that fails does not advance the high-water mark, so the next pass picks
the same dirty set up again. The full pass's mark-and-sweep of out-of-scope
rows is untouched and still runs only after a complete full pass.

### 6. Identity fence

`RefreshWorker` pinned each device's identity revision at enqueue time and
re-resolved at run time because of the gap the debounce introduced. The
incremental pass has no such gap: it reads the dirty uids and evaluates them in
the same pass, and `evaluate_devices/5` loads rows by uid at evaluation time.
A device merged between two passes simply stops appearing under its old uid
and appears under the survivor's, which the full pass's scope sweep already
handles. No pin is needed.

## Verification

- Incremental pass test: two devices in scope, one receives a new availability
  row after the mark, the pass evaluates exactly that device and advances the
  mark. Removing the timestamp filter must fail the test (the other device
  would be evaluated).
- Set-based write test: a page of N results produces one insert statement,
  asserted with a query counter or `Repo` telemetry, and identical rows to the
  previous per-device path.
- Ingestion test: `SweepResultsIngestor` performs no Oban insert; assert
  `Oban.Job` count in the `monitoring` queue is unchanged across an ingest.
- Statement count over a 1,000-device page of the full pass is asserted below
  a fixed ceiling (pages, not devices).

## Follow-ups

- The sweep ingestor still creates provisional devices one Ash create at a time
  and confirms detected aliases per IP. Both are per-row on the hot path and
  the next candidates once this change lands.
- Once the per-host cost is fixed, measure before adding any concurrency to
  ingestion. If it is still database-bound, in-node partitioned workers on the
  coordinator bound the fix; cross-node distribution is not indicated by an
  I/O-bound loop.
