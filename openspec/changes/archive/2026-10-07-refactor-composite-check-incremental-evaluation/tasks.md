## 1. Schema

- [x] 1.1 Migration: add `last_incremental_at` (utc_datetime_usec, nullable) to
  `composite_checks`; add index `device_agent_availability (agent_id, updated_at)`.
  `last_evaluated_at` already exists; do not add a second full-pass column.
- [x] 1.2 Expose `last_incremental_at` on the `CompositeCheck` resource with a
  system-only update action; no UI surface. The same action writes the existing
  `last_evaluated_at`.

## 2. Incremental pass

- [x] 2.1 `Scope.contains?/2`: run the scope query with an SRQL `uid:(...)` list
  for one page and an explicit `limit` of at least `@dirty_page_limit` (200).
  SRQL applies `default_limit` 100 when the request omits a limit;
  `stream_uids/2` returns up to 1,000 rows only because it passes `limit:`.
  `@dirty_page_limit` is distinct from the full pass `page_limit` of 1,000.
  Do not send `uid in (...)` or more than 200 uids.
- [x] 2.2 `Evaluation.dirty_uids/3`: take the mark with `now()` before the read.
  `@watermark_slack` is a module attribute, default two minutes. Stream pages
  of at most 200 uids whose `device_agent_availability` (for the check's
  vantage-point agents) has `updated_at > mark - @watermark_slack`, or, when a
  metadata input exists, whose configured path has
  `metadata['__fact_provenance'][path]['updated_at']` later than that same
  lagged mark. Never read `ocsf_devices.modified_time`. Filter each page
  through `Scope.contains?/2`.
- [x] 2.3 `Evaluation.run_incremental/2`: evaluate the dirty pages with
  `evaluate_devices/5` and `persist_page/4`. On success, always advance
  `last_incremental_at` to the pre-read `now()`, including when nothing was
  selected. On failure, advance nothing. Never sweep out-of-scope rows. Never
  advance `last_evaluated_at`. Do not run this pass when `last_incremental_at`
  is nil.
- [x] 2.4 `CompositeChecks.TickWorker` from `Oban.Plugins.Cron` every minute
  (`* * * * *` in `serviceradar_core/config/runtime.exs` and
  `serviceradar_core_elx/config/runtime.exs`). It inserts one
  `EvaluationWorker` job per enabled check.
  `unique: [keys: [:check_id], states: [:available, :scheduled, :executing], period: :infinity]`.
  `EvaluationWorker` has `max_attempts: 1` and never inserts a successor.
  A tick while a job for that check is available, scheduled, or executing
  inserts nothing. The next tick after completion inserts exactly one.
  When `last_evaluated_at` is nil, `last_incremental_at` is nil, or
  `evaluation_interval_seconds` has elapsed since `last_evaluated_at`, that
  job runs only the full pass. Otherwise it runs only the incremental pass.
  A successful full pass advances `last_incremental_at` to the pre-read `now()`
  and `last_evaluated_at` to `now()` at completion, including when the scope
  selected no devices. A full pass that runs longer than
  `evaluation_interval_seconds` is not due again on the next tick. An
  incremental pass advances only `last_incremental_at`. A failed pass advances
  neither.
- [x] 2.5 `ScheduleNotifier.ensure_scheduled` on enable inserts that same unique
  job for an immediate first run, with
  `unique: [keys: [:check_id], states: [:available, :scheduled, :executing], period: :infinity]`.
  `cancel` on disable or destroy is unchanged. A save while a job for that
  check is available, scheduled, or executing inserts nothing further.
- [x] 2.6 Make the page device load unconditional (`deleted_at` is nil). Skip a
  uid missing from that load: no result row and no verdict transition. Both
  passes use this load. Do not call `Resolver.follow_canonical_device_id`.

## 3. Set-based persistence

- [x] 3.1 `persist_page/4`: one `insert_all ... on_conflict` per page; keep the
  in-memory transition computation against `load_existing/2`.
- [x] 3.2 `persist_canonical_availability/3`: bulk `Device.set_availability`
  semantics, `is_available` only. One update for healthy uids and one for down
  uids; skip `:degraded` and `:unknown`. Do not call
  `update_device_statuses_available/3` (reporter-scoped; rewrites
  `last_seen_time` and sweep metadata).

## 4. Remove the ingestion hook

- [x] 4.1 Delete `CompositeChecks.Refresh` and `RefreshWorker`, their tests, and
  the call in `SweepResultsIngestor.upsert_agent_availability/5`.
- [x] 4.2 Confirm no other caller: `grep -rn "CompositeChecks.Refresh" elixir/`.
- [x] 4.3 Stamp `device_agent_availability.updated_at` with `now()` inside the
  ingestor INSERT (and keep that value on conflict). Remove the application
  `DateTime.utc_now()` assigned before `insert_all`. `now()` is
  `transaction_timestamp()`, fixed when the inserting transaction begins.
- [x] 4.4 `MergeDeviceFacts` writes `__fact_provenance[path].updated_at` with
  `now()` inside the one Ash update (`jsonb_set` with `to_jsonb(now())` or
  equivalent). Remove the application `DateTime.utc_now()` taken before that
  update opens. That update is the provenance writer the two-minute slack
  covers.

## 5. Tests (load `test-audit` first)

- [x] 5.1 Incremental pass selects devices inside the lagged window and advances
  the mark to the pre-read `now()`; removing the timestamp filter fails it. A
  metadata check selects a device only when a configured path's
  `__fact_provenance` `updated_at` is newer than the mark minus
  `@watermark_slack`. A sweep status write or `set_availability` does not
  select it. A writer whose transaction opened within the slack before the
  mark and committed after the read is selected by the next pass, and
  `changed_at` does not move when the verdict is unchanged. A 200-uid in-scope
  page returns all 200.
- [x] 5.2 Failed pass leaves both marks unchanged and inserts no evaluation job.
  The next minute tick runs the pass. A nil `last_incremental_at` runs the
  full pass, and a successful full pass over an empty scope advances
  `last_incremental_at` to the pre-read `now()` and `last_evaluated_at` to
  `now()` at completion. A successful incremental pass that selects nothing
  still advances `last_incremental_at`.
- [x] 5.3 Full pass over a page issues a bounded statement count (assert with
  Ecto telemetry); rows identical to the per-device path. `last_evaluated_at`
  advances only on that success, to `now()` at completion, so a pass longer
  than `evaluation_interval_seconds` is not due on the next tick. Incremental
  ticks do not advance it.
- [x] 5.4 Sweep ingestion leaves the Oban job count unchanged and writes no
  composite-check marker. Availability events and device invalidation
  broadcasts still publish.
- [x] 5.5 Register any new DB-lane tests in `INTEGRATION_SOURCE_DISPOSITIONS.tsv`
  and the Bazel count dictionaries.
- [x] 5.6 A device merged away between the dirty read and the write gets no
  result row and no verdict transition. The page device load, restricted to
  `deleted_at` nil, is what skips it.
- [x] 5.7 A tick during an executing job inserts nothing, and a tick after
  completion inserts exactly one job. A save while a job for that check is
  available, scheduled, or executing leaves exactly one job in those states.

## 6. Docs

- [x] 6.1 Update the `EvaluationWorker`, `TickWorker`, and `Evaluation`
  moduledocs; the "do not delete the periodic pass" rationale stays.
- [x] 6.2 CHANGELOG entry under Unreleased. Deferred: CHANGELOG has no Unreleased
  section; entries are written per version at release time and `scripts/cut-release.sh`
  validates them by version.
