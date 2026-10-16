## Context

The persistent ELK world already owns geometry, aggregate membership and bounded
Arrow tiles. Roaring belongs beside that world as a server-side query index.
The browser admits at most 64 tiles of 128 glyphs each, so it needs at most
8,192 rows of membership and state, not a second set-algebra engine.

The independent review and measured codec comparison are recorded in
`review-response.md`. This design incorporates that review and the user's
explicit choice of live pagination. Existing layout and GPU lifetime repairs
remain unchanged.

## 1. Persistent device identity

Reuse `platform.device_fleet_ordinals`. Store checked values in
`1..4294967295`, retain every assignment and tombstone, and never renumber gaps.
An existing assignment must not advance the allocator. Reject capacity
exhaustion explicitly while preserving reads. Allocate canonical devices from
all writers and backfill through resumable pages of at most 500 records.
Canonical endpoints share the device dictionary; glyphs and relation clips do
not consume device IDs. An interface dictionary is deferred until a product
requirement defines interface queries and parent authorization.

A durable dictionary epoch changes only for incompatible restoration or
replacement, independently of process restarts and layout changes. Every set
carries its dictionary epoch and device kind. Incompatible operands are
rejected. A future u64 identity protocol needs a separate migration.

Deletion removes live membership without freeing the ordinal. Merges retain
the losing identity as a tombstone and transfer membership to the survivor;
a stale event cannot revive the loser. A legitimate restore reuses its ID.
Physical retention cleanup must preserve these invariants: scrub an allocated
device to a minimal retained tombstone instead of deleting its dictionary entry.
Rollback keeps widened storage, epochs and assigned IDs. Ash resources describe
the schema; explicit SQL owns sequence and trigger invariants.

## 2. Native index and freshness

One supervised publisher per web replica applies complete typed rows in batches
of at most 500. A row contains its ordinal, live status and supported facets.
No JSON serialization is introduced between BEAM and Rust. Immutable revisions
make each query's membership, counts and source metadata coherent. Native work
runs on bounded dirty CPU workers with explicit deadlines, not normal BEAM
schedulers. Charge postings, temporary sets, retained revisions, ordinal
projections and simultaneous replacements to per-replica memory limits.

Current inventory is truth. Reuse `DevicePubSub` invalidation hints, auditing
raw writers at their actual transaction owners. A hint emitted before commit
can cause a reread of old state; add missing notifications only after the outer
transaction commits. Keep pending ordinals in native Roaring under a 512 KiB
byte cap; the 500-row read batch is not its membership capacity. Normalize UID
hints through bounded reads, with separate limits on that ingress. Coalesce
repeated IDs; overflow requests reconciliation without an unbounded mailbox.
Lost hints and restarts are repaired by rolling, bounded keyset scans. Preserve
an accepted index while preparing a replacement and report its age honestly.

There are no shared dirty bucket locks, outbox, JetStream control stream,
replica leases or replay checkpoints. These hints are control-state freshness
signals, not telemetry; the existing JetStream requirement for metrics is
unchanged. No index consumer may block an inventory transaction.

Full rolling reconciliation remains the completeness backstop. Existing
`identity_revision` is per-device and does not cover every facet update;
`modified_time` is not commit order. Neither is a safe global cursor, and a
finite timestamp overlap cannot cover arbitrarily late commits. Any future
incremental database cursor needs its own late-commit proof. Reconciliation
reads share a bounded worker and rate budget with dirty updates, so a large
fleet cannot create an unbounded scan or starve new hints. A configured cadence
is not a guarantee that a million-row scan finishes within that interval.

Expose seed readiness, last completed reconciliation, oldest pending work,
source errors and unavailable facets. Exact counts mean exact for the returned
published revision, not a claim that the entire fleet was read in one database
transaction. On incomplete seed, exhausted memory or a source that cannot
provide its advertised semantics, return an explicit unavailable/stale status.

## 3. Supported sources

| Facet | Source |
| --- | --- |
| Vendor, region, VLAN, device class | Canonical Device vendor_name, region, vlan_uid and normalized type_id/type. |
| OS name/version | Allowlisted canonical Device.os fields. |
| Tags | Explicitly configured canonical Device.tags keys; no arbitrary JSON-path indexes. |
| IP/CIDR | Any current canonical device or interface IP; typed IPv4/IPv6 containment returns device membership. |
| Availability | Current canonical availability using the existing world-health semantics: healthy, unavailable or unknown. |

Missing values use the documented unknown bucket. Cap facet count, key length,
value length, value cardinality and retained bytes. A facet that exceeds its
budget becomes wholly unavailable; never return a partial index as exact.

Causal state has no approved fleet-scale producer today. The legacy bounded
scene evaluator is not such a producer, and availability cannot substitute for
causality. Site/role, alerts, incidents, impact and complete search-set adapters
also remain unsupported until canonical source and completeness contracts are
approved. This feature adds no replacement causal engine.

### Map filter experience and prefix semantics

The map exposes a visible filter builder, not only a JavaScript setter. Operators
can combine inventory VLANs, supported canonical fields and configured tags using
AND, OR and EXCEPT; clear restores the base view without waiting for the index.
The server advertises supported fields, configured tag keys, operators and
readiness in bounded manifest metadata. Unconfigured or incomplete sources are
explicitly unavailable; they never silently broaden a query. Numeric device
class values and canonical VLAN identifiers are labeled honestly. Inventory VLAN
means the recorded device assignment, not proof that a switch carries a VLAN on
any port. A separate carried-VLAN predicate needs a complete canonical source.

Text starts-with matching applies to indexed scalar values and configured tag
keys. Tag-key prefix matching selects devices with a nonempty matching configured
tag, optionally constrained by an exact value or value prefix. Prefixes are
literal, case-sensitive strings after the existing canonical whitespace
normalization; they are not regular expressions or glob programs. A bounded
value-dictionary range and Roaring union is sufficient unless measurements
justify a trie. A cap must reject the predicate rather than return a partial
union. Prefix evaluation shares the query deadline and allocation accounting.

IP/CIDR is a different operator: parse IPv4/IPv6 numerically and match any known
current device or interface address. Several matching addresses on one device
count once. Never combine per-device address-bit postings from different
addresses: that can synthesize an address the device does not have. Keep address
associations native, account their memory, and construct the result bitmap from
exact address containment. Invalid input and incomplete address projection fail
explicitly; no HTTP-handler fleet scan, per-IP high-cardinality scalar facet or
interface ordinal dictionary is introduced. Canonical address source details,
publication bounds and native structure must be settled and measured before
these requirements can be marked complete.

## 4. Authorized queries and live pages

Accept normalized `all`, `any`, `except`, exact/prefix facet-value predicates,
configured tag-key prefixes and typed IP/CIDR predicates, with
32 predicates, depth 8, at most 50 requested facet values, a 16 KiB control
request, at most eight concurrent query workers and a 1 second end-to-end deadline. Control parameters may be JSON;
bulk membership and row state may not. Never fall back to a fleet scan in an
HTTP handler.

For current authorized live universe U, compute R = U AND expression.
Negation is relative to U. Facets are conjunctive: count(R AND facet_value),
including same-facet predicates. Empty results succeed with zero counts.
One request pins one native revision for its results, facets, aggregate counts
and metadata, then releases it. There is no result cache or cross-request pin.

Revalidate current RBAC at admission and delivery, including search, details,
counts, 304 responses and overlay frames. Current deployment-wide policy can
produce all or none of the live universe; finer visibility must come from real
policy. No tenants, bypass actors or parallel authorization model are added.
Revocation cancels pending work and clears client membership.

Pages use stable ordinal > last_ordinal over the receiving pod's current
published index. Authenticated cursors bind dictionary epoch, entity kind,
normalized query digest, current authority fingerprint and last ordinal. The
request resubmits its bounded expression. Source/index revisions are response
freshness metadata, not an owning-node address. A later page can reflect changed
membership; newly matching earlier ordinals require restarting from page one.
Changing query, authority or dictionary requires a new cursor. Pod loss does
not require routing to an old owner. Layout-bound detail cursors still enforce
the existing world generation and candidate/page limits.

## 5. Tile projection and binary overlay

Filtering changes visibility and counts, never ELK positions or parent links.
With no selected query, the base view remains available and preserves boundary
portals without starting a membership stream. An explicit all-devices query is
still a query and obeys all membership and unsupported-boundary guards.
Intersect R with admitted glyph membership in native code. Leaves use persistent
ordinals; aggregates use world-bound canonical membership and return exact
authorized match counts. Do not enumerate whole aggregates in BEAM or the
browser just to count them. Relations require both authorized endpoints or an
explicit authorized aggregate/bundle population; unsupported boundary selectors
remain hidden rather than exposing unrelated members.

Build the world's canonical ordinal projection in the existing supervised world
loader after geometry installation and index seeding. Stream dictionary pages
of at most 500 identities, retaining a native u32 vector rather than another UID
map. Seal and install it only against the exact accepted native world. Missing
canonical identities remain excluded and are reported as incomplete mapping;
bounded rescans repair later allocations without using sequence order as commit
order. A complete mapping can be reused for that immutable world and dictionary.
Limit generated portable aggregate selectors to 8 MiB for an entire admitted
view, independently of the much smaller outgoing row frame. Include export
scratch and temporary BEAM binaries in peak-memory reporting.

Keep existing limits: 128 glyphs, 512 edges and 256 KiB per tile, 64 admitted
tiles, four concurrent fetches and 32 MiB geometry cache. The membership budget
remains 8 MiB including retained CPU/GPU buffers and temporary staging. Reject
work before excessive allocation. Filtered detail pages retain 128-device,
256-relation and 4,096-candidate limits; unsupported filtered scenes fail
explicitly rather than broadening the result.

Negotiate a versioned little-endian binary overlay aligned to exact Arrow tile
row order. Each full replacement binds dictionary epoch, query digest, current
authority fingerprint and admitted-view receipts. Include source/index revision
metadata and a lossless sequence; revisions are never unsafe JavaScript numbers.
Per tile, include coordinates, exact tile revision and row count, followed by
contiguous matching u8, causal-state u8, availability-state u8 and matched-count
u32 columns. Native projection produces these bounded buffers directly.

Causal codes are 0=root_cause, 1=affected, 2=healthy, 3=unknown; release one emits
unknown. Availability is a separate domain: 0=healthy, 1=unavailable, 2=unknown.
An aggregate gets a known availability only when its authorized matching members
are nonempty and unanimously in that state; mixed and empty populations are
unknown. Leaf counts are zero or one; aggregate counts are exact intersections.

Use full atomic replacements, not XOR deltas or chunk assembly. At the maximum
admitted row count, the four columns occupy 57,344 bytes before bounded receipts
and envelope, fitting one 256 KiB frame. Validate every receipt, length, enum
and row count before replacing accepted masks. Discard obsolete sequences and
late responses. A missed intermediate full replacement does not corrupt the
next frame. Changes to query, authority, layout or admitted receipts require a
matching replacement; pending filters never display unfiltered success.

Allow only one unacknowledged full frame per connection. Coalesce updates by
reading current membership after acknowledgement; retain no queued frame history.
An acknowledgement stalled for fifteen seconds causes one reset. Reconnect
requires a fresh replacement. Eviction, disconnect and
feature disable release masks; valid geometry survives membership resets.
No roaring-wasm, browser worker or per-view UID dictionary is added.

Phase 3 also replaces the existing per-tile health/flow JSON response, rather
than leaving it beside a new membership stream. Encode directional rates,
coverage, eligibility, explicit unknown values and observation timestamps as
bounded typed binary fields. Keep telemetry revisions separate from membership
revisions and preserve the current four-request scheduler. Each tile's binary
response stays within 256 KiB; edge telemetry is not accumulated into a single
64-tile frame. Encode once after telemetry reads and cache the binary payload;
the HTTP route serves it directly under a negotiated binary MIME type. Replace
JSON encoding used only for size checks with the actual binary frame budget.
Keep native health epochs in their existing opaque hexadecimal domain and
preserve integer revisions losslessly. Small query/control metadata may remain JSON, but no bulk
health or flow arrays are wrapped in JSON or embedded as JSON inside a binary
envelope. The rollout-disabled compatibility path is identified separately.

An aggregate's existing traffic rate describes its whole represented bundle.
Hide the relation, traffic animation and rates if either endpoint has only
partial query membership, until an exact filtered-relation calculation is
implemented. Two partially matched endpoints do not prove that any underlying
link joins their matching members. A
whole-bundle rate must never be presented as the filtered population's rate.

Arrow attributes stay typed. Measure IPC decode, native projection, transport,
mask staging and GPU upload copies separately. WebGPU uploads do not establish
end-to-end zero copy. Queued commands must finish before referenced buffers are
destroyed or replaced.

## 6. Rollout and measurement

The topology_bitmap_enabled flag defaults false and composes with the existing
God View gate. Enable only after identity, convergence, authorization, synthetic
scale and actual-hardware browser checks pass. Disabling releases resources and
returns explicit unsupported-filter state while the bounded base view remains.
Deployment, release and destructive data cleanup require separate authorization.

Use independently synthetic 100,000 infrastructure plus 1,000,000 canonical
endpoint devices, compact and sparse IDs including values above 2^31. Declare
seed, facet distributions, selectivity, churn, machine, compiler, concurrency,
sample count and warmup. Report p50/p95/p99 and peak memory.

| Measurement | Acceptance |
| --- | --- |
| Four-term native query | p95 below 5 ms; report authorization/end-to-end latency separately. |
| Query plus fifty exact facets | p95 below 50 ms on one revision. |
| Native memory | Steady index-owned memory below 200,000,000 bytes per replica; include maps and retained revisions. Bound replacement peak separately and report cluster totals. |
| Churn | Measure one-percent full-population updates, convergence, database read load and serialized admitted-view overlays. Full overlays must fit 256 KiB and resident membership 8 MiB. |
| Fanout | At least 100 concurrent synthetic views, including slow viewers, with bounded total work and retained bytes. |
| Recovery | Two replicas with missed hints and restart must converge through bounded reconciliation; pages may land on either replica. |
| Browser | Repeated zoom, eviction, reconnect, authority change and disable; retained CPU/GPU bytes and actual-hardware frame timing. |

Compare against an independently measured array baseline. A Rust tuple scan is
not proof of the old JavaScript renderer's cost. Report full-fleet Roaring set
bytes separately if useful; the original whole-fleet XOR wire target does not
apply to an admitted-row overlay protocol. Test adversarial cardinality, empty
results, merges/deletes/restores, late commits, malformed frames and revocation.
Benchmarks and fixture provisioning use declared Bazel targets on BuildBuddy.
No unmeasured carrier-grade or end-to-end zero-copy claim is made.
