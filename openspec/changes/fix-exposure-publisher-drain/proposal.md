# Proposal: fix exposure publisher drain rate and legacy job tail

## Why

#6547 is live on demo and fixed the maintenance-queue starvation, but the
publisher drains about one scope per minute: 17 scopes completed in 20 minutes
with 2,991 still pending (about 2.5 days to drain), and normal arrival (about
2.4 scopes a minute the previous day) outpaces it. Completions land exactly
60 seconds apart and generations live about 59 seconds each, so the drain is
gated by the every-minute maintenance tick: each scope publishes quickly, then
waits for the next tick's `Finalizer.step` to mark it complete. The tick wait
is the whole bottleneck, not generation, publish, or settle work.

Separately, four old-style `ExposureSnapshotWorker` Oban rows inserted by
previous pods during the #6547 roll (after the migration ran) still execute
and snooze forever. The migration converts rows present at deploy time only;
rows inserted after it by old pods during the roll survive, and nothing
terminates them.

## What changes

- The singleton publisher finalizes a drained generation inline in its own
  pass (`Finalizer.step` after the drain is observed) instead of waiting for
  the maintenance tick. Serial order, fencing, and budgets are unchanged; the
  tick remains as a backstop. No parallelism: publication stays one generation
  at a time.
- A scan or warehouse failure during the inline step waits (bounded) instead
  of failing the scope; the tick backstop still converges it.
- A legacy `ExposureSnapshotWorker` Oban row executed from the queue no
  longer publishes or snoozes: when its scope row exists it completes
  immediately; when absent it inserts the scope row (adopt-if-absent) and
  completes; when it names no scope it cancels. Direct calls keep the legacy
  synchronous-publish-or-snooze contract for repair tooling and boundary
  tests. Nothing enqueues legacy rows anymore, so the roll-time gap is
  closed at the execution layer and needs no migration.
- Completing a scope clears its stale `error` value.

## Non-goals

- No parallelism or extra publisher slots; the serial fence is deliberate.
- No change to generation fencing, envelope idempotency, repair dispatch, or
  the maintenance backstop.
- No new credential storage and no demo edits by hand.
