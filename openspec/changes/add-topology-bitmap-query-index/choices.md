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

### Keep map sharing limited to its existing camera contract

- When: filter-builder integration.
- Choice: Share map keeps its existing layout/camera URL. Filter expressions are
  not encoded in that URL. Named Prefix Tag discovery keeps one page of 50 labels
  plus the selected label, without downloading or searching the full catalog.
- Gap: the approved filter UI did not define persisted queries, share links or
  catalog search.
- Reach: a recipient must recreate the filter, and large label catalogs require
  paging. These are public limitations, not completed sharing/search features.
- Verdict: sound for the approved scope; keep the limitations explicit.
- Confidence: medium.

### Count canonical mapping lifetime through actual native reclamation

- When: final delivery and memory review.
- Choice: at most two native canonical mappings may exist, including mappings
  pinned by in-flight responses or waiting for native reclamation. New builders
  receive backpressure until an older allocation drops. Health retains only
  its world and manifest; it does not retain the separate canonical mapping.
- Gap: per-mapping caps alone did not bound overlap between builders, cache
  replacement and delayed channel responses.
- Reach: mapping retries can delay newly available filters, while accepted
  projections remain usable through transient index-owner failures. Final
  delivery compares the exact mapping, not only its dictionary epoch.
- Verdict: sound; memory and receipt coherence follow actual resource lifetime.
- Confidence: high.

### Preserve existing source-prefix spellings while accepting mapped IPv6 masks

- When: named Prefix Tags normalization review.
- Choice: a configured network `::ffff:192.0.2.7/120` becomes the IPv4 network
  `192.0.2.0/24`, so it matches a device whose stored address was already
  normalized to IPv4. Existing prefix sources also accept the shorter mapped
  spelling `/24`; that established source behavior stays valid. Masks between
  33 and 95 are rejected. The new map query syntax uses standard mapped IPv6
  lengths of 96 through 128.
- Gap: source prefix parsing previously skipped valid standard mapped masks;
  the query design did not account for its established short-mask spelling.
- Reach: both existing prefix engines and the native catalog share the same
  network membership. Existing configured prefixes do not change meaning.
- Verdict: sound; accept the missing standard form without breaking existing
  source data, while keeping the new query syntax unambiguous.
- Confidence: high.

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

### Publish filter capabilities without making the base map depend on them

- When: integrated binary delivery checkpoint.
- Choice: the map manifest advertises configured fields and whether membership
  can currently be projected. A user can still navigate an unfiltered map while
  the dictionary mapping is being built or a filter source is unavailable.
  The browser cannot mistake an empty list of filters for a ready empty result.
- Gap: the approved UI needed supported-field discovery but did not place it.
- Reach: the existing authenticated manifest owns this small metadata response;
  no fleet-value download or extra request is needed to discover basic fields.
- Verdict: sound; current authorization is checked after metadata preparation.
- Confidence: high.

### Resolve named Prefix Tags through the existing immutable prefix snapshots

- When: named Prefix Tags implementation.
- Choice: selecting a label such as `office` reads the networks already attached
  to that label, merges their overlapping ranges, and passes those ranges to the
  device address index. A small reverse index points into the existing trie;
  it does not copy the labels or build another database of prefix ownership.
  Background work prepares it, and all retained reverse indexes together have
  a four-MiB cap. An unavailable catalog makes that filter unavailable while
  normal prefix enrichment and other topology filters continue to work.
- Gap: the user requested existing named groups but did not choose how to join
  their networks to device membership or bound discovery work.
- Reach: labels are paged, old captured snapshots remain coherent during reload,
  and full-chain tag membership preserves overlapping network labels. A label
  exceeding the range budget fails explicitly instead of returning partial
  membership. The existing trie remains the sole owner of prefix definitions.
- Verdict: sound; shared immutable data avoids per-device prefix lookups and a
  second source of truth. Catalog preparation and release remain the topology
  publisher's responsibility when the feature is enabled or disabled.
- Confidence: medium.

### Drain native ownership during graceful publisher shutdown

- When: final replica lifecycle review.
- Choice: trap supervisor exits so the publisher's termination callback runs,
  and retry busy native closes synchronously for up to four seconds. Reuse the
  normal disable cleanup; timers addressed to a terminating owner cannot finish
  that work. The budget fits inside the supervisor's default five-second limit.
- Gap: the shutdown contract did not account for dirty NIF work continuing after
  its caller dies or an external reference keeping the native resource alive.
- Reach: graceful shutdown fences new work and releases the retained index once
  active operations finish. An exhausted budget emits a warning. Untrappable
  process kills remain outside this graceful-shutdown guarantee.
- Verdict: sound; the existing native busy-close test and hosted replica
  lifecycle test own the two boundaries without introducing a second owner.
- Confidence: medium; the full remote unit gate passed, while the hosted
  database lifecycle acceptance remains pending.

### Measure transport with prepared frames and a separate server process

- When: task 4.7 negotiated compression acceptance.
- Choice: prepare the same 35 synthetic membership frames before opening the
  measurement window. A real Phoenix socket sends them through Bandit to Gun
  clients in a separate VM. When 100 clients ask for their next frame, Linux
  process CPU counts the server's serializer, zlib and kernel work without
  including client decompression. Preparation and query work stay outside that
  measurement; the test does not replace hosted production-channel acceptance.
- Gap: the task required concurrent transport cost but did not choose an
  isolation boundary or a portable source of native CPU/memory accounting.
- Reach: this manual Linux target can repeat the compression comparison without
  database fixtures. It cannot establish whole-application capacity or the
  production acknowledgement policy. RSS includes the prepared-frame fixture.
- Verdict: sound; real upgrades and byte parity exercise the missing transport
  boundary, while independent OS counters include native work.
- Confidence: high.

### Keep compression disabled after the measured CPU tradeoff

- When: task 4.7 final remote run.
- Choice: at 100 simultaneous viewers, compressing mixed synthetic frames saves
  about 56% of payload bytes but spends 22.49 CPU seconds instead of 0.39 for
  3,000 deliveries. Keep the existing disabled production setting. The manual
  probe uses 30 deliveries after five warmups, four server schedulers and the
  client's naturally negotiated context takeover; it does not guess a safe
  production update rate from a short loopback saturation test.
- Gap: no operational bandwidth/CPU budget or required update cadence was
  specified, and shared RBE timing varies between runs.
- Reach: enabling compression later needs an explicit deployment tradeoff;
  these results provide evidence without silently changing every socket.
- Verdict: sound; retain the current setting and the measured limits.
- Confidence: medium; a bandwidth-constrained deployment may choose differently.
