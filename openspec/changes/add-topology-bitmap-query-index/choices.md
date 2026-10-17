# Implementation decisions

Current decisions in the integrated implementation, ordered with the remaining
acceptance uncertainty first. A sound decision is not a claim that its hosted
acceptance has completed. Historical alternatives belong in the review response.

## Reconcile missed hints without shared inventory-writer locks

- Choice: existing best-effort hints coalesce native Roaring dirty work, while
  complete bounded keyset scans repair missed updates. A later scan repairs a
  transaction that committed after the preceding scan passed its device.
- Gap: neither a timestamp overlap nor per-device revisions form a proven
  global commit log; durable shared dirty buckets coupled unrelated writers.
- Reach: convergence depends on measured database read throughput. Inventory
  writers do not wait on shared dirty locks or an additional durable relay.
- Verdict: sound; preserves current-membership correctness while avoiding
  database write contention. Reconciliation cost remains an acceptance gate.
- Confidence: medium.

## Keep map sharing limited to its existing camera contract

- Choice: Share map keeps its existing layout/camera URL. Filter expressions are
  not encoded in that URL. Named Prefix Tag discovery keeps one page of 50 labels
  plus the selected label, without downloading or searching the full catalog.
- Gap: the approved filter UI did not define persisted queries, share links or
  catalog search.
- Reach: a recipient must recreate the filter, and large label catalogs require
  paging. These are public limitations, not completed sharing/search features.
- Verdict: sound for the approved scope; keep the limitations explicit.
- Confidence: medium.

## Hide relations whose filtered endpoints cannot be established

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

## Build the canonical world mapping after geometry becomes available

- Choice: the normal world loader first installs geometry, then streams pages
  of canonical identities into a compact native vector. A new world rejects
  the old world's pending map. Missing assignments remain excluded and the UI
  reports incomplete mapping. Dictionary epoch, maximum ordinal and row count
  determine whether another scan is needed; row count covers late lower-ordinal
  commits. A newer geometry generation preempts optional scans after the current
  bounded page. Progress and page queries share the five-second source bound.
  Identical sealed assignments preserve the accepted mapping resource.
- Gap: the plan did not choose which existing owner joins world membership to
  persistent device identity.
- Reach: filters may wait for initial mapping, while unfiltered navigation
  stays available. An unchanged incomplete world does not cause repeated full
  scans or client resets. The progress aggregate still performs work proportional
  to dictionary size; its database cost must be measured at scale.
- Verdict: sound; one existing loader owns the work and avoids a fleet UID map.
- Confidence: medium.

## Resolve named Prefix Tags through the existing immutable prefix snapshots

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

## Drain native ownership during graceful publisher shutdown

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

## Keep compression disabled after the measured CPU tradeoff

- Choice: at 100 simultaneous viewers, compressing mixed synthetic frames saves
  about 56% of payload bytes but spends 22.50 CPU seconds instead of 0.45 for
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

## Bootstrap sparse synthetic identities without remapping existing rows

- Choice: the fixture creates new synthetic devices as inactive, then assigns
  only those new devices invented dictionary ordinals, then activates them
  through the normal trigger. The immediate device foreign key holds throughout
  the single 500-row transaction. No index starts before this bootstrap ends. Compact IDs use consecutive ordinals; sparse
  IDs begin above 2^31 and advance by seven. Existing dictionary rows and
  tombstones keep their values. Real device triggers still execute.
- Gap: production allocation is intentionally dense, so a fresh scratch
  database cannot naturally produce sparse high IDs at this population.
- Reach: this tests separated high IDs, not every possible u32 distribution.
  Native full-u32 boundary tests remain the owner of extreme values.
- Verdict: sound; explicit fixture bootstrap avoids claiming that identity
  reassignment is a supported production operation.
- Confidence: medium.

## Reject hidden starvation and report sampled memory honestly

- Choice: normal clients emulate the renderer's bounded retry delay and must
  each accept a fresh revision within 30 seconds during ready churn. Cold
  owner restart is measured separately. Every deliberately slow client must
  observe its own reset; the limit allows the server's five-second polling
  interval after its 15-second ACK threshold. One-second server samples are
  accompanied by native reservation peaks and Linux process high-water RSS.
- Gap: aggregate throughput can look healthy while a few viewers never
  progress, and current native bytes omit earlier peaks and unrelated heaps.
- Reach: a busy or starved client can fail acceptance even when other viewers
  are fast. RSS includes the full server; component reservation caps are
  reported separately and are not presented as a total process-memory bound.
- Verdict: sound; individual progress and explicit measurement limits make
  the result falsifiable. The 30-second readiness bound is an acceptance
  workload choice, not a new product response-time promise.
- Confidence: medium.

## Preserve retired identities while allowing policy-valid successor seeding

- Choice: retention scrubs mutable payload but preserves UID, partition, ordinal,
  deletion reason and merge lineage. The user chose to allocate tombstoned
  ordinals for previously unallocated purge candidates within the existing
  locked batch transaction. Older deleted rows therefore retain identity even
  if backfill never reached them. The user also chose a durable successor pointer so repeated
  address reuse can keep allocating fresh identities after payload purge,
  without increasing the eight-read attempt bound. Locked observed revisions
  fence concurrent writers; creation and pointer advancement commit together.
  Source-retired devices remain blocked. Preserved partition, structural defaults and valid fresh timestamps keep a
  legitimately restored retained row readable. Service components receive no
  new device ordinal; existing reserved assignments are retained but excluded.
- Gap: permanent identity retention must not accidentally make normal address
  reuse impossible or broaden automatic restoration policy.
- Reach: purge queries and fixture cleanup distinguish retained identities from
  live or unpurged devices. Dictionary and inventory locks have finite deadlines, with
  dictionary widening separate from inventory lifecycle DDL. Hosted database
  lifecycle assertions still have to run against the final integrated code.
- Verdict: sound; preserves identity and existing lifecycle policy together.
- Confidence: medium pending hosted migration and lifecycle acceptance.

## Keep permanent dictionary protection during rollback

- Choice: the user chose to retain delete/truncate protection on migration
  rollback. Rollback must keep a compatible retention-cleanup binary or backport,
  or pause cleanup before using an older incompatible binary.
- Gap: reversing the allocation/lifecycle triggers alone cannot safely restore
  an older cleanup implementation that deletes reserved ordinals.
- Reach: rollback is a coordinated operation; migration documentation names the
  requirement. Both table locks are acquired without waiting before lifecycle DDL.
- Verdict: sound; a migration reversal cannot make permanent identity reusable.
- Confidence: medium pending hosted migration and lifecycle acceptance.

## Preserve synthetic fixture constraints and measure causal progress

- Choice: each device has a unique invented IPv6 primary address and a shared
  interface IPv4 address. Churn replaces the primary /48. SQL-derived final
  assertions check new and removed prefixes; authority denial must increase
  each client's forbidden count after deactivation.
- Gap: repeated primary addresses violate real uniqueness constraints, and
  historical closes do not prove a later authority revocation was observed.
- Reach: the harness exercises real schema and transport boundaries without
  weakening constraints, remapping existing ordinals or claiming browser proof.
- Verdict: sound; combined hosted execution remains pending.
- Confidence: medium pending compact and sparse hosted acceptance.

## Count canonical mapping lifetime through actual native reclamation

- Choice: at most two native canonical mappings may exist, including mappings
  pinned by in-flight responses or waiting for native reclamation. New builders
  receive backpressure until an older allocation drops. Health retains only
  its world and manifest; it does not retain the separate canonical mapping.
  Native index admission also includes the actual pending dirty-bitmap charge.
  Intrinsic IP capacity exhaustion latches IP unavailable while scalar and hint
  publication continue under unchanged limits.
- Gap: per-mapping caps alone did not bound overlap between builders, cache
  replacement and delayed channel responses.
- Reach: mapping retries can delay newly available filters, while accepted
  projections remain usable through transient index-owner failures. Final
  delivery compares the exact mapping, not only its dictionary epoch; an
  identical sealed assignment retains that resource rather than invalidating it.
  A complete projection skips dictionary count/page reads entirely until the
  world or dictionary epoch changes; unrelated allocations cannot change it.
  Sealing computes its assignment digest within the existing one-second deadline
  and publishes readiness only after successful completion. Test-only collection
  makes cap-two reclamation checks deterministic without changing production GC.
- Verdict: sound; memory and receipt coherence follow actual resource lifetime.
- Confidence: high.

## Keep capacity until cancelled channel work actually finishes

- Choice: unwatch/reset clears the requested result but retains the channel's
  occupied task slot until its existing worker exits. A new watch receives busy
  during that interval, under the unchanged one-second query deadline.
- Gap: killing an outer task does not stop its separately supervised inner
  query; repeated watches could consume the whole eight-worker pool.
- Reach: other viewers retain capacity, cancelled frames are discarded, and
  there is no additional global owner registry to leak after killed workers.
- Verdict: sound; task lifetime stays with the channel that already owns it.
- Confidence: high.

## Run scale acceptance within the existing guarded lifecycle and time limits

- Choice: compact and sparse each use one existing dispatch-only WebNgDbDiagnostic
  action and guarded disposable clone. Network/plugin checks remain, and ordinary
  BazelCI correctness stays required separately. Refuse scale admission unless
  both observer and action can fit the test, quiet period and bounded cleanup.
- Gap: the user retained all limits; the action clock includes checkout and
  preparation, while unbounded cleanup could outlive an otherwise passing test.
- Reach: the 44-minute scenario stays inside its 45-minute test limit. The
  observer's 55-minute ceiling shrinks to fit the remaining runner budget;
  test/observer/cleanup envelopes include forced-exit grace. Each cleanup command
  gets sixty seconds, and lease release is attempted even after teardown fails.
  The existing two-hour lease needs no extra renewal or new provisioner.
- Verdict: sound; slow preparation refuses before workload admission, and slow
  cleanup remains an explicit failed run rather than a false acceptance claim.
- Confidence: medium until hosted distributions exercise cleanup and timing.

## Reject surrounding whitespace in filter text

- Choice: reject empty or surrounding-whitespace values in both builder and
  parser, while preserving internal spaces literally.
- Gap: a starts-with value ending in a space was silently shortened, selecting
  a broader group than the operator entered.
- Reach: scalar and configured tag-key/value predicates share one policy;
  source normalization is unchanged and invalid input stays visible for correction.
- Verdict: sound; explicit rejection preserves the approved literal semantics.
- Confidence: high.

## Preserve existing source-prefix spellings while accepting mapped IPv6 masks

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

## Live result pages use current local membership

- Choice: page two reads the receiving pod's current index after the last
  ordinal, so devices may enter or leave between pages. Counts within one
  response still share one coherent snapshot.
- Gap: resolved by the user's product preference for a live NOC view.
- Reach: no frozen export guarantee, retained query owner, routing or result cache.
- Verdict: sound; cursor binds query, dictionary and current authority.
- Confidence: high.

## Encode telemetry once, preserving its separate update schedule

- Choice: a tile's health and directional traffic become one bounded binary
  payload after the telemetry query. The cache retains those bytes, and HTTP
  serves them directly. Matching masks use a separate whole-view frame, so
  changing a filter does not require re-querying telemetry for every tile.
- Gap: the reduced proposal required binary replacement but did not specify
  how existing telemetry caching and membership cadence share transport.
  Keep the current fixed SRTO codec; native Arrow encoding is an explicit
  follow-up requiring parity and allocation/wire measurements before replacement.
- Reach: two small, explicit row protocols share exact geometry receipts;
  telemetry fields retain coverage, unknowns and observation timestamps.
- Verdict: sound; replaces bulk JSON while preserving bounded source reads.
- Confidence: high.

## Use one outstanding membership frame and current-policy delivery

- Choice: after sending a complete membership frame, the server waits for its
  acknowledgement before computing another. The five-second tick resets a
  stream whose acknowledgement has stalled for fifteen seconds. Every completed response rechecks the current user policy, dictionary
  and world before sending; no history queue or old query owner survives.
- Gap: the plan required bounded slow-viewer behavior without choosing the
  acknowledgement and cancellation lifecycle.
- Reach: slow viewers see current replacements instead of accumulating deltas;
  eight query workers and a one-second request deadline bound expensive work.
- Verdict: sound; full replacement makes dropped intermediate states harmless.
- Confidence: high.

## Interpret current IP membership through current address owners

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

## Publish filter capabilities without making the base map depend on them

- Choice: the map manifest advertises configured fields and whether membership
  can currently be projected. A user can still navigate an unfiltered map while
  the dictionary mapping is being built or a filter source is unavailable.
  The browser cannot mistake an empty list of filters for a ready empty result.
- Gap: the approved UI needed supported-field discovery but did not place it.
- Reach: the existing authenticated manifest owns this small metadata response;
  no fleet-value download or extra request is needed to discover basic fields.
- Verdict: sound; current authorization is checked after metadata preparation.
- Confidence: high.

## Measure transport with prepared frames and a separate server process

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

## Use real server paths while declaring the synthetic geometry boundary

- Choice: two isolated BEAM VMs run the production bounded source, index,
  authentication, endpoint and channel. Gun opens 100 actual sockets. An
  invented native world is installed at WorldCache, then its mapping is built
  from real dictionary pages. For example, a database availability change must
  reach an independently decoded socket frame before that viewer progresses.
- Gap: the plan did not choose whether this slice should also run discovery,
  layout persistence and a physical browser. Those have separate existing
  owners and evidence; combining all of them would obscure the server costs.
- Reach: the result covers database-to-network behavior and whole-server RSS,
  but cannot be advertised as full browser, layout or ingestion acceptance.
- Verdict: sound; the narrower boundary is explicit and exercises real
  production behavior without new production hooks or dependencies.
- Confidence: high.

## Send bounded typed rows after server-side Roaring evaluation

- Choice: Roaring computes device sets on the server. The browser receives
  counts and masks for its admitted geometry, without a Roaring runtime or a
  second set-algebra implementation.
- Gap: a tiled view does not require browser set algebra over the whole fleet.
- Reach: fixed-width row cost is independent of sparse device ordinal values;
  the browser still validates receipts and performs explicit aligned copies.
- Verdict: sound; codec measurements favor typed columns for this boundary.
- Confidence: high.

## Admit telemetry before fetching and bind membership to displayed geometry

- Choice: deterministic numeric z/x/y order admits complete telemetry tiles
  within the five-MiB cache budget before fetching. Omitted tiles show unknown
  telemetry. Membership receipts include displayed tiles only; offscreen
  geometry prefetch remains available without invalidating the active query.
- Gap: per-tile limits alone did not prevent a visible working set from
  repeatedly evicting and fetching itself or prefetch from restarting watches.
- Reach: dense views can show unknown telemetry on omitted tiles, while filter
  membership remains valid for every admitted displayed row.
- Verdict: sound; explicit omission bounds work and avoids repeated refetching.
- Confidence: high.

## Retry incomplete membership with bounded backoff

- Choice: malformed frames and stream resets retry after one, two, four, eight,
  then ten seconds. A newly acknowledged watch does not erase this history;
  reconnecting and cancelling a binding preserve it too. An accepted complete
  frame, a new query, changed receipts or actual support changes reset it.
  Each replacement uses a fresh view epoch. The synthetic network harness uses
  the same schedule.
- Gap: a successful watch can still produce no usable membership frame.
- Reach: repeated failures cannot create a fast resubscription loop; transient
  failures may take up to the existing capped retry delay to recover.
- Verdict: sound; public browser regression cases establish the lifecycle.
- Confidence: high.

## Refresh source versions without rebuilding the filter form

- Choice: one shared capability-identity function omits only Prefix Tags source
  versions. Full source descriptors and membership freshness checks remain.
- Gap: catalog publication changes version frequently without changing which
  operators a user can select.
- Reach: version updates retain draft focus, label discovery and active queries;
  actual field/operator/source changes still invalidate unsupported state.
- Verdict: sound; source freshness and supported controls have different owners.
- Confidence: high.

## Remove hidden glyph picking without copying geometry

- Choice: hidden nodes use zero stroke width as well as zero radius and minimum
  pixel size. Existing row order and packed glyph-position buffers are reused;
  filtering adds no geometry repack. Initial decoding/packing still copies data.
- Gap: transparent styling does not remove geometry from the GPU picking pass.
- Reach: the per-row stroke attribute adds bounded style storage under the
  existing allowance; no filtered geometry arrays or increased caps are needed.
  Admission counters remain distinct from a complete JavaScript heap census.
- Verdict: sound; real GPU picking with a visible underlay verifies the narrower
  fix and avoids an unnecessary compaction path.
- Confidence: high.
