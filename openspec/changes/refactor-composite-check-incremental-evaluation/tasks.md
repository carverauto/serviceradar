## 1. Schema

- [ ] 1.1 Migration: add `last_incremental_at` (utc_datetime_usec, nullable) to
  `composite_checks`; add index `device_agent_availability (agent_id, updated_at)`.
  `last_evaluated_at` already exists; do not add a second full-pass column.
- [ ] 1.2 Expose `last_incremental_at` on the `CompositeCheck` resource with a
  system-only update action; no UI surface. The same action writes the existing
  `last_evaluated_at`.

## 2. Incremental pass

- [ ] 2.1 `Scope.contains?/3`: run the scope query restricted to one page of uids;
  same `page_limit` bound as `stream_uids/2`.
- [ ] 2.2 `Evaluation.dirty_uids/3`: take the mark with `SELECT now()` before the
  read. `@watermark_slack` is a module attribute, default two minutes, longer
  than the availability upsert transaction. Stream in pages the uids whose
  `device_agent_availability` (for the check's vantage-point agents) has
  `updated_at > mark - @watermark_slack`, or, when a metadata input exists,
  whose configured path has
  `metadata['__fact_provenance'][path]['updated_at']` later than that same
  lagged mark. Never read `ocsf_devices.modified_time`. Filter each page
  through `Scope.contains?/3`.
- [ ] 2.3 `Evaluation.run_incremental/2`: evaluate the dirty pages with
  `evaluate_devices/5` and `persist_page/4`. On success, always advance
  `last_incremental_at` to the start-of-pass database clock, including when
  nothing was selected. On failure, advance nothing. Never sweep out-of-scope
  rows. Never advance `last_evaluated_at`. Do not run this pass when
  `last_incremental_at` is nil.
- [ ] 2.4 `EvaluationWorker`: reschedule with `schedule_in` equal to the
  incremental interval (30s). When `last_evaluated_at` is nil,
  `last_incremental_at` is nil, or `evaluation_interval_seconds` has elapsed
  since `last_evaluated_at`, run only the full pass. Otherwise run only the
  incremental pass. A successful full pass always advances both clocks to its
  start clock, including when the scope selected no devices. An incremental
  pass advances only `last_incremental_at`.
- [ ] 2.5 `EvaluationWorker` `max_attempts: 1`. Oban `unique`: `period: 10`
  (strictly shorter than the 30s reschedule gap), `keys: [:check_id]`,
  `states: [:available, :scheduled]` (not `:executing`, not `:retryable`).
  `perform` inserts the successor on success, error, and raise. A failed pass
  advances no mark; the successor is the retry. One attempt means no second
  chain.
- [ ] 2.6 On the shared page path, before the write, batch
  `Resolver.follow_canonical_device_id` for the page in one query. Skip a uid
  that does not resolve to a live device. Never write a result for a
  merged-away uid. Both passes use this path.

## 3. Set-based persistence

- [ ] 3.1 `persist_page/4`: one `insert_all ... on_conflict` per page; keep the
  in-memory transition computation against `load_existing/2`.
- [ ] 3.2 `persist_canonical_availability/3`: bulk `Device.set_availability`
  semantics, `is_available` only. One update for healthy uids and one for down
  uids; skip `:degraded` and `:unknown`. Do not call
  `update_device_statuses_available/3` (reporter-scoped; rewrites
  `last_seen_time` and sweep metadata).

## 4. Remove the ingestion hook

- [ ] 4.1 Delete `CompositeChecks.Refresh` and `RefreshWorker`, their tests, and
  the call in `SweepResultsIngestor.upsert_agent_availability/5`.
- [ ] 4.2 Confirm no other caller: `grep -rn "CompositeChecks.Refresh" elixir/`.
- [ ] 4.3 Stamp `device_agent_availability.updated_at` with `now()` inside the
  ingestor INSERT (and keep that value on conflict). Remove the application
  `DateTime.utc_now()` assigned before `insert_all`. `now()` is
  `transaction_timestamp()` and does not by itself keep a late commit inside
  the next window; `@watermark_slack` does.

## 5. Tests (load `test-audit` first)

- [ ] 5.1 Incremental pass selects devices inside the lagged window and advances
  the mark; removing the timestamp filter fails it. A metadata check selects a
  device only when a configured path's `__fact_provenance` `updated_at` is
  newer than the mark minus `@watermark_slack`. A sweep status write or
  `set_availability` does not select it. A row that commits after the read
  with `updated_at` just before the stored mark is selected by the next pass,
  and `changed_at` does not move when the verdict is unchanged.
- [ ] 5.2 Failed pass leaves both marks unchanged. A nil `last_incremental_at`
  runs the full pass, and a successful full pass over an empty scope advances
  both clocks. A successful incremental pass that selects nothing still
  advances `last_incremental_at`.
- [ ] 5.3 Full pass over a page issues a bounded statement count (assert with
  Ecto telemetry); rows identical to the per-device path. `last_evaluated_at`
  advances only on that success, and incremental ticks do not advance it.
- [ ] 5.4 Sweep ingestion leaves the Oban job count unchanged and writes no
  composite-check marker. Availability events and device invalidation
  broadcasts still publish.
- [ ] 5.5 Register any new DB-lane tests in `INTEGRATION_SOURCE_DISPOSITIONS.tsv`
  and the Bazel count dictionaries.
- [ ] 5.6 A device merged away between the dirty read and the write gets no
  result row for the merged-away uid. A uid that does not resolve to a live
  device is skipped.
- [ ] 5.7 A failing `EvaluationWorker` pass, including a raise, leaves exactly
  one scheduled successor for that check and does not advance either mark.

## 6. Docs

- [ ] 6.1 Update the `EvaluationWorker` and `Evaluation` moduledocs; the
  "do not delete the periodic pass" rationale stays.
- [ ] 6.2 CHANGELOG entry under Unreleased.
