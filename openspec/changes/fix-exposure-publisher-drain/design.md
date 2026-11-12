# Design: inline finalization and legacy adopt-and-discard

## Context

Each scope's generation publishes in seconds, then the publisher's
`await_completion` waits (up to 10 minutes) for the generation to settle.
Settling requires `Finalizer.step`, which runs only on the every-minute
maintenance tick. Measured on demo: completions exactly 60 s apart,
generations living ~59 s each. The tick wait dominates; generation, publish,
and settle work do not.

## Decisions

### D1 — Finalize drained generations inline in the publisher pass

After `track_generation`, the pass waits for the drain (status `finalizing`
with empty receipts backlog, bounded by the existing completion budget), then
calls `Finalizer.step` directly and maps the result:

- `:ok` completes the scope immediately (today's complete path).
- `finalization_pending` / `repairs_pending` (repairs dispatched) waits for
  settle with the remaining budget (today's wait path).
- `incomplete` (warehouse still draining) keeps waiting with the remaining
  budget.
- `input_missing` (gap abort) fails the scope as aborted (today's semantics).
- Any other error (warehouse scan failure, custody conflict, step race)
  waits with the remaining budget and never fails the scope directly; the
  maintenance tick still converges it.

Preserved guarantees: serial order (one generation at a time), fencing
(unchanged engine), at-least-once (complete only after generation
completes), bounded waits (existing budgets). The maintenance tick keeps
calling `step` as a backstop; the call is idempotent (status/cursor guards).

Rejected: shortening the maintenance cadence (fleet-wide cost for a
publisher-local wait), and a second publisher slot (breaks the serial
fence the design is built on).

### D2 — Legacy queue rows adopt-and-discard; direct calls unchanged

A legacy `ExposureSnapshotWorker` row executed by Oban (integer job id) does
not publish and never snoozes:

- Its scope row exists (any status) → return `:ok`; the row is deleted and
  the scopes table (publisher loop plus maintenance backstop) owns the
  scope. This covers the roll-time orphans with no republish and no lock
  contention.
- Its scope row is absent → insert it `pending` if absent (never touching
  existing rows), ensure the publisher, return `:ok`. A row without
  `device_ord` names the fleet-wide (NULL) scope, which old pods still
  enqueue during the roll, and adopts the same way.
- Invalid scope (not an integer >= 1) → `{:cancel, :superseded}`.

Direct calls (`%Oban.Job{}` with no id: repair tooling and the live
broker-driven boundary tests) keep the exact legacy
synchronous-publish-or-snooze contract, including the prepare insert. The
queue/direct split is by job id because that is exactly the boundary that
matters: queued rows are owned by the scopes table, direct calls are not.

Rejected: deleting the rows by hand on demo (not repeatable, leaves the gap
open), and a new migration (one-shot; cannot catch rows inserted after it
runs — the same hole that stranded these rows).

### D3 — Clear the stale error on completion

`Scopes.complete/2` sets `error = NULL`. Completed rows today retain the
last failure's error text, which misreports healthy scopes and confuses
drain reporting.

## Verification

- Fail-first DB tests on `codex_*` scratch databases: legacy adopt-and-discard
  (queued row with covered scope completes deleted with no new generation;
  unknown or fleet-wide scope inserts pending; invalid scope cancels), inline-step result
  mapping without StarRocks (incomplete/aborted/scan-error cases), plus the
  existing publisher/scopes suites.
- Gate: `no-mistakes` review (not claude), `gh pr merge --merge`.
- Demo: report the drain rate from scope rows written after the rollout
  (completions per minute from `updated_at` ordering), compared against the
  ~1/minute pre-fix baseline.
