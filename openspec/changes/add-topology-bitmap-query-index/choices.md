# Implementation decisions

Intermediate ledger; consolidate against final shipped code before handoff.

## Unsound decisions corrected

### Shared durable buckets for unrelated device changes

- When: first integration pass, rejected during independent review.
- Choice: several devices shared a locked dirty-work row. Two inventory writers
  changing different devices could acquire these rows in opposite order and
  abort one another. A per-statement sort did not order whole transactions.
- Gap: the proposal required durable coalescing but did not choose its storage.
- Reach: every raw inventory writer would inherit contention from the index.
- Verdict: unsound. Current-state hints do not justify a replication subsystem;
  remove it and reconcile missing hints without shared writer locks.
- Confidence: high.

### Browser Roaring for already bounded tile rows

- When: browser prototype, replaced after measured comparison.
- Choice: every admitted view allocated a codec runtime and decoded portable
  sets before producing row masks. Sparse IDs made those sets larger than the
  masks, even after a custom build reduced the heap.
- Gap: the original issue suggested browser bitmaps without proving a need for
  local set algebra after tiling bounded the view.
- Reach: runtime dependency, toolchain, worker lifecycle and protocol complexity.
- Verdict: unsound for this product path. Send the final bounded typed columns.
- Confidence: high.

## Sound decisions

### Keep complete rolling reconciliation until commit coverage is proven

- When: review reshaping.
- Choice: if an update commits after a scan passed that device and its hint is
  lost, a later bounded scan repairs it. A timestamp overlap can miss a longer
  transaction, and the existing per-device revision is not a global commit log.
- Gap: the simpler review direction proposed an incremental cursor without a
  proven commit-order source.
- Reach: database read budget and honest convergence age remain rollout gates.
- Verdict: sound; preserve correctness while measuring cost.
- Confidence: medium.

### Retain minimal canonical tombstones during physical cleanup

- When: device identity pass.
- Choice: a deleted device with a persistent ordinal keeps its UID and deletion
  lineage while mutable payload is scrubbed. Deleting its dictionary would let
  future membership reuse or lose a previously assigned identity.
- Gap: the previous cleanup owner deleted child dictionaries before deleting
  the device; the proposal did not detail physical retention behavior.
- Reach: purge queries and fixture cleanup must distinguish retained identity
  from a live or unpurged device.
- Verdict: sound; immutable identity survives cleanup and legitimate restoration.
- Confidence: high.

### Live result pages use current local membership

- When: explicitly chosen by the user on 2026-10-16.
- Choice: page two reads the receiving pod's current index after the last
  ordinal, so devices may enter or leave between pages. Counts within one
  response still share one coherent snapshot.
- Gap: resolved by the user's product preference for a live NOC view.
- Reach: no frozen export guarantee, retained query owner, routing or result cache.
- Verdict: sound; cursor binds query, dictionary and current authority.
- Confidence: high.
