# Proposal: skip stale exposure scopes at claim time

## Why

#6547 replaced the per-device snooze storm with one serial publisher, and
`fix-exposure-publisher-drain` (in gate) finalizes drained generations inline.
The publisher still drains about one scope a minute, with thousands pending.
Live profile on demo 2026-11-12 (read-only CNPG + JetStream, build 54):

- 360 generations completed in 6 h, 49–62 s each (avg 57 s), completions
  exactly ~60 s apart: the drain is serial per-scope cost, not scheduling.
- A typical scope (1890/1891): publish phase (create to finalizing) ~20 s,
  settle phase (finalizing to complete) ~36 s, every minute, metronomic.
- Manifests and receipts are all-zero pages, `pending`/`repairs` empty,
  cursor `[0,0,0]`: no data moves. Settle is one warehouse scan that returns
  no rows, plus the end-marker pipeline wave.
- CNPG is proven fast (`pg_stat_statements`: every exposure query ≤2.5 ms
  mean). The ~56 s is pipeline waves plus the StarRocks scan, not the database.
- All 1,631 pending scopes carry reconciliation verdict `matched`
  (source == warehouse), requested in a single 2-minute burst at 01:36 during
  a core restart, never re-requested. Their checks matched ~12 h before their
  generations publish. Zero duplicate scope rows.
- The StarRocks query client caps at 15 s (`mysql.ex`), so a ~36 s settle
  implies a timed-out first scan attempt plus retry, or a slow end-marker
  wave under demo saturation — stated as uncertainty, not fact.

Root cause of the missed drain rate: scopes outlive their own fulfillment.
A request from a 12-hour-old mismatch publishes an empty generation at full
56 s cost. Every one of the 1,631 pending scopes is already converged.

## What changes

- At claim time the publisher checks whether a complete generation covering
  the scope finished after the scope was last requested
  (`Scopes.fulfilled_since_request?/1`, using the same coverage rule as
  `ExposureReadiness.latest_generation/1`, so global generations count,
  compared against the scope row's `not_before`). If so the scope completes
  immediately with no generation, no pipeline waves, and no warehouse scan.
- At-least-once is preserved: requests are level-triggered (the sweep
  re-requests while a device mismatches, resetting `not_before`), so a
  wrongly skipped scope is re-requested by the next sweep, not lost. The
  common case (request hours older than dozens of intervening generations)
  carries no risk; the boundary race is analyzed in `design.md`.
- Nil (global) scopes always publish; only aborted-or-newer-complete logic
  applies — an aborted generation never fulfills a scope.
- Serial order, fencing, budgets, and id-keyed completion are unchanged. A
  skipped scope completes through a generation-less variant that still
  requires the `publishing` claim, so a concurrent re-pend cannot be
  completed by a stale claim.
- The publisher's orphan adoption additionally sweeps legacy-format
  `ExposureSnapshotWorker` Oban rows at startup with the same
  adopt-then-terminate rule the queue clause already applies at execution:
  adopt the scope if absent (fleet-wide when `device_ord` is missing), then
  complete the row; invalid rows cancel. Deploy-time close of the roll-time
  gap; execution-time behavior is unchanged.

## Non-goals

- No parallelism; publication stays one generation at a time.
- No change to genuine-scope latency (waves + scan under saturation) and no
  warehouse schema or scan redesign — follow-up work if genuine arrivals
  exceed ~1/min after the stale backlog clears. Current arrivals: zero in
  the measured window.
- No change to the sweep, readiness, comparison, or repair logic.
