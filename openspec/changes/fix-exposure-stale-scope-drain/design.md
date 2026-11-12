# Design: stale scope skip and legacy sweep

## Fulfillment rule

A scope row with `not_before = T` (last request time; every `Scopes.request/1`
upsert resets it to now) is *fulfilled* when a generation in state `complete`
covers the scope with completion time `G > T`. Coverage is the existing
`ExposureReadiness.latest_generation/1` rule: a generation whose control scope
is NULL (global) or equals the scope ordinal.

On claim the publisher runs one `EXISTS` query for that condition. Fulfilled
implies a generation-less completion; otherwise the scope publishes exactly
as today.

## Why at-least-once survives

1. Requests are level-triggered, not edge-triggered. The reconciliation sweep
   re-requests every device whose comparison mismatches (resetting
   `not_before` to now), and matched devices with unready readiness do the
   same. A scope is pending *while* it is still needed.
2. A skip only fires when a complete generation is strictly newer than the
   last request. In the common case the request is hours old with dozens of
   intervening generations: the world the request described no longer exists,
   and re-validation at claim time is strictly fresher than validation at
   request time.
3. Boundary race: a change commits at `T + e`, a generation snapshots at
   `T + d` (`d < e`) and completes at `G > T`. The skip fires although the
   generation missed the change. The next sweep still sees the mismatch
   (warehouse lacks the change) and re-requests with a fresh `not_before`,
   so the change publishes one sweep period later. Delay, never loss. The
   sweep period bounds the delay; no new timer is introduced.
4. Aborted generations never fulfill: the query only matches
   `status = 'complete'`. A scope whose only newer generation aborted
   publishes normally, preserving the existing abort-recovery paths.
5. Nil scopes (global re-publication) always publish: a global skip would
   need snapshot-ordering proof the per-scope rule deliberately avoids.
6. The generation-less completion requires `status = 'publishing'` on the
   claimed row id, exactly like the id-keyed `complete/2`. A re-pended row
   (status reset to `pending` by a concurrent request) cannot be completed
   by a stale claim; the claim is simply lost and the row stays pending.

## What is deliberately not decided here

- Whether a *mismatched* scope with a newer complete generation could still
  need the scan for gap detection: it cannot happen, because a complete
  generation newer than the mismatch request already ran the scan for that
  scope (the scan is part of every generation's settle). The skip reuses
  that generation's gap detection instead of repeating it.
- Genuine-scope latency (pipeline waves, scan cost under saturation) is
  out of scope; see the proposal's non-goals.

## Legacy sweep at startup

`adopt_orphans` already runs once per publisher pass under the session lock.
It additionally lists Oban rows for the legacy worker
(`ServiceRadar.Inventory.ExposureSnapshotWorker`, non-publisher, states
available/scheduled/retryable) and, per row, applies the execution-time rule
without executing: an integer `device_ord` adopts that scope, a missing
`device_ord` adopts the fleet-wide scope (`Scopes.adopt_legacy/1`,
insert-if-absent, never touching an existing row), and the row completes; a
row naming an invalid scope cancels outright. Idempotent and safe to repeat:
adoption never modifies an existing scope row, and only rows no production
code enqueues anymore match. The execution-time clause stays as the backstop
for rows inserted between passes.

## Alternatives considered

- Re-validate with a fresh comparison digest at claim time: runs the full
  source/warehouse diff per scope (the expensive part of the sweep) and
  duplicates reconciliation in the publisher. Rejected.
- Cancel pending scopes when the sweep records `matched`: writes sweep
  policy into reconciliation and races the publisher's claim. The claim-time
  check is local to the publisher and needs no cross-worker protocol.
  Rejected.
- Drop the scan for empty manifests: the scan is the gap detector; an empty
  manifest with stale warehouse rows is exactly what it catches. Rejected.
