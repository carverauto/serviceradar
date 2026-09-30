## 1. Schema

- [ ] 1.1 Migration: add `last_incremental_at` (utc_datetime_usec, nullable) to
  `composite_checks`; add index `device_agent_availability (agent_id, updated_at)`.
- [ ] 1.2 Expose `last_incremental_at` on the `CompositeCheck` resource with a
  system-only update action; no UI surface.

## 2. Incremental pass

- [ ] 2.1 `Scope.contains?/3`: run the scope query restricted to one page of uids;
  same `page_limit` bound as `stream_uids/2`.
- [ ] 2.2 `Evaluation.dirty_uids/3`: stream in pages the uids whose
  `device_agent_availability` (for the check's vantage-point agents) or
  `ocsf_devices` (when a metadata input exists) `updated_at` is later than the
  mark; filter each page through `Scope.contains?/3`.
- [ ] 2.3 `Evaluation.run_incremental/2`: evaluate the dirty pages with
  `evaluate_devices/5` and `persist_page/4`; advance `last_incremental_at` only
  on success; never sweep out-of-scope rows.
- [ ] 2.4 `EvaluationWorker`: run the incremental pass every interval; run the
  full pass when `evaluation_interval_seconds` has elapsed since the last full
  pass; a full pass also advances the mark.

## 3. Set-based persistence

- [ ] 3.1 `persist_page/4`: one `insert_all ... on_conflict` per page; keep the
  in-memory transition computation against `load_existing/2`.
- [ ] 3.2 `persist_canonical_availability/3`: one set-based update per page per
  availability value, following the sweep ingestor's
  `update_device_statuses_available/3` precedent.

## 4. Remove the ingestion hook

- [ ] 4.1 Delete `CompositeChecks.Refresh` and `RefreshWorker`, their tests, and
  the call in `SweepResultsIngestor.upsert_agent_availability/5`.
- [ ] 4.2 Confirm no other caller: `grep -rn "CompositeChecks.Refresh" elixir/`.

## 5. Tests (load `test-audit` first)

- [ ] 5.1 Incremental pass selects only changed devices and advances the mark;
  removing the timestamp filter fails it.
- [ ] 5.2 Failed pass leaves the mark unchanged.
- [ ] 5.3 Full pass over a page issues a bounded statement count (assert with
  Ecto telemetry); rows identical to the per-device path.
- [ ] 5.4 Sweep ingestion leaves the Oban job count unchanged.
- [ ] 5.5 Register any new DB-lane tests in `INTEGRATION_SOURCE_DISPOSITIONS.tsv`
  and the Bazel count dictionaries.

## 6. Docs

- [ ] 6.1 Update the `EvaluationWorker` and `Evaluation` moduledocs; the
  "do not delete the periodic pass" rationale stays.
- [ ] 6.2 CHANGELOG entry under Unreleased.
