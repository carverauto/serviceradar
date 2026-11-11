Every test task loads the `test-audit` skill first. Every fixture, harness and demo dataset
is synthetic: documentation address ranges (`192.0.2.0/24`, `198.51.100.0/24`,
`203.0.113.0/24`, `2001:db8::/32`), invented names, and no values exported from a running
deployment. DB tests run only on `codex_*` scratch databases on srql-fixtures, or in CI.
Every regression test must be seen to fail before the fix.

## 1. Spec

- [x] 1.1 Proposal, design, requirements, and tasks for the single publisher with
      scopes table; `openspec validate redesign-exposure-snapshot-publisher --strict`
      green and internally consistent on arrival.

## 2. Scopes table and engine extraction

- [x] 2.1 Migration: `platform.exposure_snapshot_scopes` with `scope_ord`
      (`UNIQUE NULLS NOT DISTINCT`), status, generation, attempts, `not_before`,
      claim/lease columns, and error.
- [x] 2.2 Extract the per-scope publish path from `ExposureSnapshotWorker`
      into `publish_scope/2` loop control flow (fence, pages, receipts,
      completion unchanged); the direct-drive `perform/1` keeps the original
      synchronous-publish-or-snooze contract, `use Oban.Worker` is removed, and
      `recover_reader/0` is deleted in favor of publisher adoption.
- [x] 2.3 Migration backfill: distinct scopes from queued
      (`available`/`scheduled`/`retryable`) `ExposureSnapshotWorker` Oban rows
      become pending scope rows; those Oban rows are deleted; `executing` rows
      stay for lifeline through the retained `perform/1`. Fail-first DB test
      with seeded Oban rows (device ordinals plus one fleet-wide row).

## 3. Publisher worker

- [x] 3.1 `ExposureSnapshotPublisherWorker` (maintenance queue, singleton
      unique over available/scheduled, `max_attempts: 20`): claim loop with
      `SKIP LOCKED` FIFO, orphan adoption (complete marks without republish,
      still-publishing aborts and re-pends, published/finalizing left alone),
      bounded waits (5-minute budget, 3 rounds, then release and exit), exit
      on empty, quiet exit on a held lock.
- [x] 3.2 FIFO order test; crash-mid-drain resume test (complete generation
      marked without republish, orphaned generation aborted and republished
      once, live pipeline generation untouched); poison-scope containment test
      (others complete, attempts counted, dead-letter telemetry, attempt `:ok`).
- [x] 3.3 Stale-generation adoption test: publishing row with expired lease
      and orphaned generation is aborted and republished; live-pipeline rows
      are never adopted.

## 4. Demand signals and backstop

- [x] 4.1 Replace all six `Publisher.new` insert sites (five reconciliation,
      finalizer full-generation, maintenance missing-input) with scope upserts
      plus singleton ensure; delete `recover_reader` (adoption owns that path);
      prepare completion (`stage == "done"`) ensures the publisher.
      Fail-first: asserting tests that previously expected Oban rows now
      expect scope rows.
- [x] 4.2 Maintenance backstop: unrestored scope work ensures the publisher.
      Fail-first test.
- [x] 4.3 Remove the per-scope `ExposureSnapshotWorker` Oban interface (`use
      Oban.Worker` gone; `perform/1` kept as the direct-drive contract);
      update `exposure_assessment_transitions_db_test.exs` and any other
      assertions that expect per-device publisher jobs.

## 5. Verification and landing

- [ ] 5.1 Full verification: touched-area `make test` path, contract test,
      quality gates, then the no-mistakes gate (reviewer not claude).
- [ ] 5.2 PR description notes the epic design amendment (new Decision
      appended to `add-srql-exposure-intelligence/design.md`). Merge with
      `--merge`.
