# Design: single exposure snapshot publisher with a scopes table

Amends the exposure epic (`add-srql-exposure-intelligence`, issue #5745):
the publisher mechanics below replace the per-device Oban fan-out while the
epic's publication semantics (serial fenced generations, envelope-hash
idempotency, receipts, finalization) stay exactly as specified.

## Context

Today every scope that needs publication becomes an `ExposureSnapshotWorker`
Oban job (unique by `device_ord`). Each job opens by contending for one
session advisory lock; losers `{:snooze, 5}`. With ~3,660 scopes the queue
executes millions of no-op snoozes and starves every other maintenance worker.
The jobs are a distributed queue for work that is inherently sequential — one
generation publishes at a time, each fenced by its own MVCC snapshot.

## Decision 1: pending scopes live in `platform.exposure_snapshot_scopes`

One row per scope, updated in place (the `exposure_reconciliation_checks`
pattern), so the table is bounded by fleet size plus one fleet-wide row:

- `scope_ord bigint NULL` — NULL is the fleet-wide scope. Uniqueness with
  `NULLS NOT DISTINCT` (precedent in `20260809120000`).
- `status text` — `pending | publishing | preparing | failed | dead | complete`.
- `generation_id bigint NULL` — the generation currently (or last) publishing
  this scope; lets a new run distinguish "generation completed before the
  crash, just mark complete" from "orphan, abort and republish".
- `attempts int`, `not_before timestamptz`, `error text NULL`,
  `claimed_by bigint NULL` (Oban job id), `lease_expires_at timestamptz NULL`,
  timestamps. Completed rows persist as the publish ledger and are never
  deleted by the publisher.

## Decision 2: one publisher job drains the table, then exits

New `ExposureSnapshotPublisherWorker` (`queue: :maintenance`, `max_attempts: 20`,
singleton unique on `[:worker]` over incomplete states — the maintenance-worker
pattern). One execution:

1. Takes one `DirectSession` and the session advisory lock once. Oban
   uniqueness dedupes available/scheduled ensures, and the lock serializes
   runs: a pass that finds the lock held exits quietly because the running
   drain already covers the table.
2. Adopts orphans: `publishing` rows whose lease expired. If their generation
   is complete, marks the scope complete with no republish. If it is still
   `publishing`, aborts the generation with its recorded owner and
   `:reader_lost` — the existing proof (holding the session lock proves the
   reader is gone) — and re-pends the scope for republication with a fresh
   generation. A `published` or `finalizing` generation belongs to the
   maintenance/finalizer pipeline and is left alone; the backstop re-ensures
   until its completion marks the scope complete.
3. Claims the next due row (`pending`, `preparing`, or `failed`;
   `not_before <= now`; `ORDER BY id`, `FOR UPDATE SKIP LOCKED` for
   multi-node safety) and runs the existing per-scope engine for it.
4. Repeats until no claimable row exists, then returns `:ok` and exits. No
   `{:snooze, _}` anywhere on this path.

Per-scope outcomes stay inside the loop: `complete` advances; `preparing`
(plus `not_before` backoff and a prepare-worker ensure) skips to the next
scope; a scope error increments `attempts`, sets `not_before` backoff and
`failed`, and continues draining — one poison scope never blocks the rest.
Past the attempts cap (10) the row goes `dead` with error telemetry and stays
queryable; the next demand signal re-pends it. The attempt returns `:ok`
unless the process itself crashes, so Oban retries cover crashes only.

Today's `coordinate` snooze sites map to loop control flow, preserving
behavior: a stale `publishing` generation is aborted through the reader-lost
proof (the lock proves it) and the scope proceeds; unsettled downstream lanes
and foreign `published`/`finalizing` generations pause the loop on bounded 5 s
rechecks (5-minute budget per wait round, at most 3 rounds, then the scope is
released and the pass exits) — the maintenance backstop below re-ensures the
publisher. Both budgets default in code and follow the existing
`:exposure_snapshot_timeout_ms` application-config precedent. The engine keeps
its direct-drive `perform/1` with the original synchronous-publish-or-snooze
contract (used by repair tooling and the broker-driven boundary tests);
`recover_reader/0` is deleted and its replacement demand is owned by scope
rows. `use Oban.Worker` is removed from the engine, so nothing can enqueue a
per-scope job again.

## Decision 3: every demand signal writes a row and ensures the job

The six `Publisher.new` insert sites become scope-row upserts plus a
unique-insert ensure of the singleton (no-op when one is pending or running):
the five reconciliation paths, the finalizer's full-generation queue, and the
maintenance worker's missing-input path. Additionally:

- `recover_reader/0` is deleted; orphan replacement demand is owned by scope
  rows and the publisher's adoption pre-pass.
- `ExposurePublicationPrepareWorker`, on reaching `stage == "done"`, ensures
  the publisher (preparing scopes may now be due).
- The every-minute maintenance worker gains a backstop: unrestored scope work
  (`pending`, `publishing`, `preparing`, or `failed` rows) implies ensure the
  publisher. Over-ensuring is free (lock-held or quiet runs exit immediately).
  This closes the only missed-wakeup path (publisher exiting on an exhausted
  wait budget, crash, or deploy).

## Decision 4: migration converts in-flight Oban demand

One SQL migration, in order: create the table and indexes; insert one
`pending` row per distinct scope from queued `ExposureSnapshotWorker` Oban
rows (`worker = 'ServiceRadar.Inventory.ExposureSnapshotWorker'`,
`state IN ('available', 'scheduled', 'retryable')`,
`args->>'device_ord'`, NULL when absent); delete those Oban rows. Demand is
preserved exactly once: converted rows are pending (never double-published by
the migration, since publishing only happens through claimed rows), and no
queued old publisher job can run afterward because its row is gone.
`executing` rows are deliberately excluded: Oban lifeline resumes them, and
they still publish through the retained direct-drive `perform/1`.

## Guarantees

- **Ordering:** FIFO by scope-row id. Generations fence independent source
  views, so order changes only latency. The fleet-wide (NULL) scope takes its
  FIFO turn like any other scope.
- **At-least-once:** rows complete only after generation completion is
  observed. Crash before that republishes with a fresh fence; envelope hashes
  dedupe any double delivery, identical to today's retry semantics.
- **No silent drops:** failed and dead rows persist with their errors;
  completed rows persist as the ledger. Nothing on this path truncates or
  deletes publish obligations.
- **Bounded queue impact:** steady state runs zero publisher executions when
  the table is empty. The million-execution snooze loop is gone; the remaining
  periodic work is the pre-existing every-minute maintenance singleton.
