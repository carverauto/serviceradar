# Proposal: single exposure snapshot publisher with a scopes table

## Why

`ExposureReconciliationWorker` fans out one `ExposureSnapshotWorker` Oban job
per device (~3,660 on demo). Publication is serial deployment-wide — one
session advisory lock — so every waiting job returns `{:snooze, 5}`. Each job
has been snoozed ~390 times: well over a million no-op executions through the
`maintenance` queue, which is what holds every-minute maintenance workers ~100 s
late and piles up duplicate cron ticks. The polling is the flaw; moving the
workers to another queue would only move it.

## What changes

- One `ExposureSnapshotPublisherWorker` job drains pending device scopes from a
  new `platform.exposure_snapshot_scopes` table instead of thousands of
  per-scope jobs polling the serial lock. The job exits when the table is
  empty; demand (reconciliation, finalizer, maintenance backstop, prepare
  completion) inserts scope rows and ensures the singleton job. No snooze
  loops on the singleton path: one pass waits boundedly in-execution instead
  of thousands of jobs polling. The engine keeps its direct-drive `perform/1`
  snooze contract; nothing enqueues it.
- The per-scope publish engine (fenced generation, bounded pages, receipts,
  finalization) is reused unchanged; only job plumbing becomes loop control
  flow. Publication stays serial, one generation at a time.
- Ordering: FIFO by scope-row id. Generations are independent (each fences its
  own MVCC snapshot), so order affects latency only, never correctness.
- At-least-once: a scope row completes only after its generation completes. A
  crash republishes the scope with a fresh generation; duplicate delivery is
  absorbed by the existing envelope-hash idempotency, exactly as today's
  retry semantics.
- Crash-mid-publish resume: the next run adopts lease-expired `publishing`
  rows, completes without republish when the generation finished, aborts a
  still-`publishing` generation through the existing session-lock proof
  (holding the lock proves the reader is gone) and republishes, and leaves
  `published`/`finalizing` generations to the maintenance/finalizer pipeline.
- Migration: a SQL migration creates the table, backfills one row per distinct
  scope from queued (`available`/`scheduled`/`retryable`)
  `ExposureSnapshotWorker` Oban rows, and deletes those rows. No demand is
  lost; no scope publishes twice from the migration alone. `executing` rows
  stay for Oban lifeline through the retained direct-drive `perform/1`.
- Poison scopes fail without blocking others: per-scope attempts with
  `not_before` backoff, a dead-letter status with telemetry after the cap, and
  rows retained (never dropped). The attempt returns `:ok`; Oban retries cover
  crashes only.

## Non-goals

- The reconciliation per-ordinal jobs keep their shape (bounded, one-shot each;
  not the polling problem). The prepare worker's bounded paging snoozes stay.
- No new queue, no Helm knobs, no data truncation: completed scope rows persist
  as the publish ledger (one row per scope, bounded by fleet size).
- Mixed-version behavior is unchanged: queued old Oban rows are converted by
  the migration, so no queued old publisher job can run after deploy; an
  `executing` row resumed by Oban lifeline still publishes through the
  retained engine `perform/1`.
