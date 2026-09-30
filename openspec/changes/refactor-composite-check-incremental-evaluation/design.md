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

### 2. Dirty set from the timestamps the inputs read

Each check records `last_incremental_at`. It only gates the dirty read. The
mark is the database clock (`SELECT now()`) taken at the start of the pass,
before the dirty read. The incremental pass computes the dirty set as rows
with `updated_at > last_incremental_at - @watermark_slack`:

- a `device_agent_availability` row for one of the check's vantage-point
  agents;
- when the check has a `:device_metadata` input, any configured path's
  `metadata['__fact_provenance'][path]['updated_at']` (the provenance timestamp
  `Resolvers.DeviceMetadata` resolves);
- intersected with the check's scope.

`@watermark_slack` is a module attribute, default two minutes. It must exceed
the longest availability upsert transaction. The ingestor's `insert_all` is
one short statement, so two minutes covers it. The same lag applies to the
provenance comparison.

The metadata predicate reads that provenance timestamp and never
`ocsf_devices.modified_time`. `ocsf_devices` has no `updated_at`. Sweep status
writes and `Device.set_availability` do not write `__fact_provenance`, so they
do not dirty a device. A metadata key with no provenance timestamp is covered
by the full pass only.

`device_agent_availability.updated_at` moves when an observation is accepted.
The ingestor stamps it with `now()` inside the INSERT (and the conflict update
keeps that inserted value), not with an application `DateTime.utc_now()` taken
before `insert_all`. PostgreSQL `now()` is `transaction_timestamp()`, fixed
when the inserting transaction begins. An insert that began before the pass's
`SELECT now()` can stay invisible to the dirty read and commit with
`updated_at` before the mark the pass stores. The slack is what makes the next
window select that row. The stamp does not. Re-evaluating a device in the
overlap is idempotent: the same inputs yield the same verdict, and `changed_at`
does not move when the verdict is unchanged. The column has no index today;
the migration adds `(agent_id, updated_at)`.

A nil `last_incremental_at` is not an incremental read. That tick runs the
full pass, the same as a nil `last_evaluated_at`. A successful full pass
always advances both clocks to its start clock, including when the scope
selected no devices. An empty scope has nothing for a nil watermark to miss.
A successful incremental pass always advances `last_incremental_at` to its
start clock, including when it selected nothing. A failed pass advances
neither clock.

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

Canonical availability for a check with `write_canonical_availability` is a
bulk form of `Device.set_availability`: `is_available` only (the only field
that action accepts), one update for the healthy uids and one for the down
uids, skipping `:degraded` and `:unknown`. It is not the ingestor's
`update_device_statuses_available/3`. That statement matches
`availability_source_agent_id` to the sweep reporter and also rewrites
`last_seen_time` and sweep metadata. A composite pass has no sweep reporter,
so that statement updates zero rows; dropping the reporter predicate would
clobber sweep failure state. The page write does not dirty the device: it
does not write fact provenance.

### 5. One scheduler

`EvaluationWorker` wakes every `incremental_interval` (a module attribute,
default thirty seconds, not operator-facing). The full pass is due when
`evaluation_interval_seconds` has elapsed since
`composite_checks.last_evaluated_at`, when `last_evaluated_at` is nil, or when
`last_incremental_at` is nil. `last_evaluated_at` already exists and is never
written today; it is the full-pass clock. A due tick runs the full pass and
not the incremental pass, so a device is not evaluated twice for one change.
A successful full pass advances both clocks to its start clock. Every other
tick runs only the incremental pass, which advances `last_incremental_at` and
does not advance `last_evaluated_at`.

A periodic job does not need Oban retries. The next tick is the retry, and
that is safe because a failed pass advances neither mark. `EvaluationWorker`
uses `max_attempts: 1`. `perform` inserts the successor on every outcome
(success, error, and raise) with `schedule_in` equal to the incremental
interval, so a raise does not end the chain. Uniqueness stays on `check_id`
with `states: [:available, :scheduled]` (not `:executing`, not `:retryable`)
and `period: 10`, shorter than the 30-second gap. The executing job is not a
unique state, so it does not discard the successor. With one attempt there is
no retryable state and no second chain.

A pass that fails does not advance either mark, so the successor picks the
same dirty set up again. The full pass's mark-and-sweep of out-of-scope rows
is untouched and still runs only after a complete full pass.

### 6. Canonical uid at evaluation time

The incremental pass follows the canonical uid at evaluation time. For each
page it batch-resolves `Resolver.follow_canonical_device_id` in one query,
skips a uid that does not resolve to a live device, and never writes a result
for a merged-away uid. The follow sits on the shared page path both passes
use (`evaluate_devices/5` before the write), so a full pass has the same rule.
A merge between the dirty read and the write therefore cannot restore a result
row for the losing uid. No enqueue-time pin and no per-device job.

## Verification

- Incremental pass test: two devices in scope, one receives a new availability
  row after the mark, the pass evaluates exactly that device and advances the
  mark. Removing the timestamp filter must fail the test (the other device
  would be evaluated). A metadata check is dirtied only by
  `__fact_provenance` for a configured path; a sweep status write or
  `set_availability` on an otherwise unchanged device is not selected. A row
  that commits after the read with `updated_at` just before the stored mark is
  selected by the next pass. Re-evaluating it does not move `changed_at` when
  the verdict is unchanged.
- Nil `last_incremental_at` runs the full pass. A successful full pass over an
  empty scope advances both clocks. A successful incremental pass that selects
  nothing still advances `last_incremental_at`. A failing pass advances neither
  and leaves exactly one scheduled successor.
- Merge test: a device selected by the dirty read is merged away before the
  write. The pass writes no result for the merged-away uid, and skips the uid
  when the canonical follow does not resolve to a live device.
- Set-based write test: a page of N results produces one insert statement,
  asserted with a query counter or `Repo` telemetry, and identical rows to the
  previous per-device path.
- Ingestion test: `SweepResultsIngestor` enqueues no composite-check job and
  writes no composite-check marker. Assert the `Oban.Job` count is unchanged
  across an ingest. Availability events and device invalidation broadcasts
  still publish.
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
