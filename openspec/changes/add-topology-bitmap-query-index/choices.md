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

### Hide relations whose filtered endpoints cannot be established

- When: binary view integration.
- Choice: a cluster can contain ten devices but only two matches. A line to
  another partially matched cluster does not prove that any matching devices
  connect. Hide that line and its whole-bundle traffic rather than attribute
  unrelated members' traffic to the filter. With no selected query, preserve
  the base map's links, including tile-boundary portals.
- Gap: the plan required authorized relation membership without specifying
  behavior while exact filtered bundle membership is unavailable.
- Reach: filtered views may have fewer links until that projection is built;
  counts stay exact and clearing the filter restores the complete base view.
- Verdict: sound; an omitted unsupported relation is safer than a false link.
- Confidence: medium.

### Build the canonical world mapping after geometry becomes available

- When: binary view integration.
- Choice: the normal world loader first installs geometry, then streams pages
  of canonical identities into a compact native vector. A new world rejects
  the old world's pending map. Missing assignments remain excluded and a later
  bounded scan retries them; the UI reports incomplete mapping.
- Gap: the plan did not choose which existing owner joins world membership to
  persistent device identity.
- Reach: filters may wait for initial mapping, while unfiltered navigation
  stays available. Historical geometry can require repeated repair scans.
- Verdict: sound; one existing loader owns the work and avoids a fleet UID map.
- Confidence: medium.

### Encode telemetry once, preserving its separate update schedule

- When: binary telemetry integration.
- Choice: a tile's health and directional traffic become one bounded binary
  payload after the telemetry query. The cache retains those bytes, and HTTP
  serves them directly. Matching masks use a separate whole-view frame, so
  changing a filter does not require re-querying telemetry for every tile.
- Gap: the reduced proposal required binary replacement but did not specify
  how existing telemetry caching and membership cadence share transport.
- Reach: two small, explicit row protocols share exact geometry receipts;
  telemetry fields retain coverage, unknowns and observation timestamps.
- Verdict: sound; replaces bulk JSON while preserving bounded source reads.
- Confidence: high.

### Use one outstanding membership frame and current-policy delivery

- When: channel integration.
- Choice: after sending a complete membership frame, the server waits for its
  acknowledgement before computing another. A fifteen-second stall resets the
  stream. Every completed response rechecks the current user policy, dictionary
  and world before sending; no history queue or old query owner survives.
- Gap: the plan required bounded slow-viewer behavior without choosing the
  acknowledgement and cancellation lifecycle.
- Reach: slow viewers see current replacements instead of accumulating deltas;
  eight query workers and a one-second request deadline bound expensive work.
- Verdict: sound; full replacement makes dropped intermediate states harmless.
- Confidence: high.

### Interpret current IP membership through current address owners

- When: user-expanded filter scope.
- Choice: the user requested any known device/interface IP. Current primary
  addresses, active aliases, interface addresses and existing virtual interfaces
  contribute. An old IP identity record alone does not: those records may remain
  for months after reassignment. A down interface still has its assigned IP.
- Gap: the user specified breadth but not which historical/current inventory
  records establish present membership.
- Reach: IP filtering requires complete bounded association publication;
  historical address searches remain a separate product behavior.
- Verdict: sound; the filter describes current assignment, not identity history.
- Confidence: high.
