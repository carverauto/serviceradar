# ServiceRadar Atlas bitmap query design

## Context

ServiceRadar Atlas's persistent ELK world owns geometry, aggregate membership and bounded
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
Physical retention cleanup must preserve these invariants for every eligible
canonical tombstone, including rows deleted before migration or backfill.
Within the existing bounded purge transaction, lock and recheck still-deleted
candidates, allocate any missing ordinal as tombstoned, then scrub mutable
payload. Preserve UID, partition, deletion reason, merge lineage and the durable
seed-successor pointer. Allocation neither revives the row nor transfers another
device's ordinal. Internal service identities retain their existing exclusions.
Rollback keeps widened storage, epochs and assigned IDs. Ash resources describe
the schema; explicit SQL owns sequence and trigger invariants.

Repeated sweep seeding at one address allocates new identities after eligible
predecessors are purged. The deterministic address-root tombstone retains one
current-successor pointer as minimal lineage. Each attempt reads at most eight
successors, persists verified progress when that budget is exhausted, and defers
remaining work. Existing UID-sorted identity fences bind the observed head;
creation and head movement commit atomically. Merged roots do not redirect the
new seed to a merge survivor, and a source-retired head still suppresses seeding.
No old ordinal is reused. Physical scrub preserves the successor pointer.

Eligible mapper rediscovery of an identity-purged operator, DIRE, or nil-actor
tombstone allocates a fresh successor UID through the same durable
`_seed_successor` pointer and eight-read bound. The purged row and its permanent
ordinal stay. Creation and pointer movement commit together. An anchorless
provisional seed already holding the polled IP may be that published
successor, and the tombstone pointer records the adopted live UID. Merged,
source-retired, released-seed, and operator tombstones are not adoption
targets. Unpurged operator deletes stay suppressed. Merged, source-retired,
and released-seed lineage stay suppressed
and are never revived. A restorable system delete still returns as the same UID,
including one reached through the successor pointer: rehydrate it when
identity-purged and restore it when it is only soft-deleted. The walk continues
only past identity-purged operator, DIRE, and nil-actor rows. The existing
UID-sorted identity fence revalidates the root and every observed candidate or
absence before pointer movement, and a successor is published only when that
row is live and mapper-owned. A same-poll management link resolves each child
address's parent once, then uses the parent's committed live UID: the rehydrated
row when that parent is a restorable system delete, or the published successor
when rediscovery allocates one. A later poll repairs an existing or restored
child's management link only when the stored link is missing or its stored
parent is no longer live, and it records that parent's committed live UID. A
still-live stored parent stays, including when the poll names a different
device. The update uses that same condition, so a concurrent live assignment is
not overwritten. A withheld or not-yet-live parent leaves an existing link
unchanged and records no planned id.

Rollback retains dictionary deletion/truncate protection. It requires a cleanup
binary with retained-identity support (or that support backported), or cleanup
must be paused; an arbitrary older cleanup worker is unsupported. Lifecycle DDL
acquires both inventory and dictionary table locks with NOWAIT up front, so a
busy deployment fails atomically for maintenance retry instead of deadlocking
against writers. Canonical device liveness remains authoritative when historical
dictionary tombstone flags lag inventory.

## 2. Native index and freshness

One supervised publisher per web replica applies complete typed rows in batches
of at most 500. A row contains its ordinal, live status and supported facets.
No JSON serialization is introduced between BEAM and Rust. Immutable revisions
make each query's membership, counts and source metadata coherent. Native work
runs on bounded dirty CPU workers with explicit deadlines, not normal BEAM
schedulers. Charge postings, temporary sets, retained revisions, ordinal
projections and simultaneous replacements to per-replica memory limits.
Intrinsic address capacity includes the actual retained dirty bitmap charge.
Final admission holds the existing pending lock through publication, preventing
new hints from invalidating that capacity decision. Intrinsic exhaustion disables
the address facet explicitly while scalar publication and queued hints survive;
temporary reader or scratch pressure remains retryable.

Current inventory is truth. Reuse `DevicePubSub` invalidation hints, auditing
raw writers at their actual transaction owners. A hint emitted before commit
can cause a reread of old state; add missing notifications only after the outer
transaction commits. Keep pending ordinals in native Roaring under a 512 KiB
byte cap; the 500-row read batch is not its membership capacity. Normalize UID
hints through bounded reads, with separate limits on that ingress. Coalesce
repeated IDs; overflow requests reconciliation without an unbounded mailbox.
The publisher owner retains its one drained batch, at most 500 ordinals, until
publication succeeds. Native contention retries preserve that work without
requiring another queue write, setting a source error, or starting a full scan.
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
| Named Prefix Tags | Existing locally loaded immutable prefix snapshots; an exact source/label selects devices through their current addresses. |
| Availability | Current canonical availability using the existing world-health semantics: healthy, unavailable or unknown. |

Missing values use the documented unknown bucket. Bound configured field count,
key length and scalar value length independently of stored group diversity.
There is no fixed distinct-value admission ceiling. Account retained and temporary
native allocations before construction, including batch postings, strings, the
next revision's directory and pinned revisions. Preserve the 125,000,000-byte
steady and 160,000,000-byte total reservation limits, 500-row publication batch
and one-second native deadline. A rejected publication retains the preceding
atomic revision and reports stale progress; it must not disable unrelated fields
or publish a partial result. Oversized scalar values still make their field
explicitly unavailable because that field cannot be indexed completely.

Publication borrows the union of old and changed keys rather than copying an
additional complete candidate directory. It still visits the current directory
once per batch; benchmark that cost separately from exact lookup and set algebra.
The 100,000-device diversity sweep varies one or five fields from 512 through
65,536 values with only two query predicates. Those are measurement points,
not new product limits. Preserve separate large-population and hosted convergence
acceptance. Temporary pressure recovery at the native owner does not by itself
prove publisher progress when a capacity-blocked page precedes later deletions.

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
literal, case-sensitive strings over canonically normalized source values.
The builder and server reject empty input or surrounding whitespace rather than
silently trimming and broadening it; internal spaces remain literal. This applies
to exact values, scalar prefixes and configured tag-key/value predicates.
They are not regular expressions or glob programs. A bounded
value-dictionary range and Roaring union is sufficient unless measurements
justify a trie. A cap must reject the predicate rather than return a partial
union. Prefix evaluation shares the query deadline and allocation accounting.
Combine matching postings in balanced stages to avoid copying a growing union
once per distinct value; this does not require a separate text trie.

IP/CIDR is a different operator: parse IPv4/IPv6 numerically and match any known
current device or interface address. Several matching addresses on one device
count once. Never combine per-device address-bit postings from different
addresses: that can synthesize an address the device does not have. Keep address
associations native, account their memory, and construct the result bitmap from
exact address containment. Invalid input and incomplete address projection fail
explicitly; no HTTP-handler fleet scan, per-IP high-cardinality scalar facet or
interface ordinal dictionary is introduced. Canonical address source details,
publication bounds and native structure must be measured before these
requirements can be marked complete.

Current address owners are Device.ip, active device aliases, interface address
arrays and existing virtual interfaces. An administratively or operationally
down interface retains its assigned addresses. Historical IP identity records
alone are not current assignment evidence. Normalize host suffixes and zone IDs
at ingestion; normalize IPv4-mapped IPv6 consistently. Query CIDRs accept only
numeric IPv4/IPv6, with ambiguous mapped prefixes rejected explicitly.

Read each bounded device batch and its address streams from one read-only
repeatable-read transaction. Stream at most 500 associations at a time into one
unpublished native stage, with a 16 MiB stage cap and fixed timeout. Complete all
address sources before publishing that batch's scalar and IP state atomically.
An oversized or incomplete source makes IP predicates unavailable; a later
successful batch for another device cannot silently clear that condition.
Exact scalar facets can remain available. Use sorted packed native address and
reverse-owner indexes so containment and full-device address replacement need
neither fleet BEAM enumeration nor per-IP scalar postings. Charge copied leaves,
retained readers and staging to the same declared memory limits.

### Existing named Prefix Tags

The user also approved selecting existing named Prefix Tags. A predicate binds
one source and exact label. Preserve the prefix engine's existing full matching
chain: a label on any matching ancestor prefix contributes, with no invented
longest-prefix override. A label's network union intersects the current native
address index and returns deduplicated device membership.

Capture source version and immutable native handle together. Reuse the web
service's existing local loaders; query-time core RPC, per-device BEAM lookups
and prefix-table scans are forbidden. Sources absent locally are explicitly
unavailable. Label discovery returns at most 50 labels per page, binding its
live lexical cursor to source, authority and last label. Pod-local source
versions are response metadata, not cross-replica cursor identities. Reserve
at most 4 MiB total additional catalog
memory across sources and retained snapshots. Build catalogs only in the
existing background bitmap worker whenever Atlas is enabled. Retry
admission after retained snapshots release memory, and release catalogs when
Atlas stops or a source is removed. Catalog admission failure does
not break existing prefix lookup; named-tag queries report unavailability.

Return sorted, disjoint inclusive numeric ranges to the bitmap engine. Across
one query, allow at most 4,096 merged ranges and 256 KiB compiled selector
bytes, sharing the original one-second deadline. Reject overflow before partial
results escape. These limits apply in addition to the 32 user predicates and
16 KiB control request. Source versions are captured and rechecked within one
response and reported as freshness metadata. Device pagination remains live:
its cursor binds source/label expression identity, not an old prefix version.
An update between pages can therefore change membership as already approved.

## 4. Authorized queries and live pages

Accept normalized `all`, `any`, `except`, exact/prefix facet-value predicates,
configured tag-key prefixes, typed IP/CIDR and named Prefix Tag predicates, with
32 predicates, 65 expression nodes and depth 8 (root at depth 1, including every
EXCEPT wrapper), at most 50 requested facet values, a 16 KiB control
request, at most eight concurrent query workers and a 1 second end-to-end deadline. Control parameters may be JSON;
bulk membership and row state may not. Never fall back to a fleet scan in an
HTTP handler.
Each tile channel retains one occupied task slot until the actual bounded worker
finishes, even after replacement, unwatch or reset. Cancelled results are discarded.
Repeated watches receive `query_busy` without spawning more inner work; no global
per-owner registry or extra queue is introduced. Missing users are rejected before
query-pool admission. Query and tile-selection HTTP endpoints share bitmap error
statuses, with no retry header on invalid or unsupported predicates.

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
canonical identities remain excluded and are reported as incomplete mapping.
A complete projection is final for its immutable world and dictionary epoch;
reuse it without dictionary count or identity-page queries. For incomplete
projections, poll dictionary epoch, maximum ordinal and row count; unchanged progress must
not repeatedly scan an incomplete historical world. Row count detects a lower
ordinal committing after a higher one, so sequence order is not treated as
commit order. The progress aggregate and each identity page have a five-second
source-query bound. This aggregate returns bounded data but still scans the
dictionary; measure its database cost at the configured poll cadence.
A newer geometry publication takes priority over optional identity work after
the current bounded page. Seal assignments with a digest; identical assignments
for the same world and dictionary retain the accepted mapping resource and its
pending deliveries. Actual assignment changes replace it and fence stale work.
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
authority fingerprint and admitted-view receipts. Include the exact whole-query
device count; summing visible aggregate counts is incorrect when levels overlap.
Include source/index revision
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
Membership receipts describe displayed geometry only; unrelated offscreen
prefetch stays in the geometry watch without clearing accepted membership.
Validate counts against each row's represented population, including zero for
unsupported boundary rows. Do not sum overlapping tiles to validate a total.

Allow only one unacknowledged full frame per connection. Coalesce updates by
reading current membership after acknowledgement; retain no queued frame history.
An acknowledgement stalled for fifteen seconds causes one reset. Reconnect
requires a fresh replacement. Eviction, disconnect and
feature disable release masks; valid geometry survives membership resets.
Malformed frames and resets retry after 1, 2, 4, 8 and at most 10 seconds.
Only an accepted complete frame resets the attempt counter; a successful watch
binding is not recovery. Changed queries or displayed receipts start a new
retry epoch.
Reconnect and empty dirty-tile reconciliation preserve the retry signature and
attempt count. A Prefix Tags source-version refresh updates freshness metadata
without resetting the builder or unchanged membership; actual source identity,
support, discovery or readiness changes still invalidate capability identity.
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
envelope. An enabled Atlas always advertises and serves this binary protocol.
Admit telemetry before fetching in stable numeric tile order, reserving maximum
row bytes and CPU/GPU metadata allowances within the 5 MiB retention cap.
Unadmitted telemetry stays explicitly unknown until the viewport admission
changes, avoiding repeated fetch/eviction cycles on a stationary dense view.

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

Filtering is available whenever Atlas is enabled through the existing
`SERVICERADAR_GOD_VIEW_ENABLED` lifecycle gate. There is no separate bitmap
feature-off switch. Existing `analytics.view` and `devices.view` permissions
govern access, including named Prefix Tag discovery. Clearing the expression
restores the base map; unavailable or failed active queries remain explicit and
never silently show an unfiltered success. Stopping Atlas releases its native,
catalog and renderer resources. Identity, convergence, authorization, synthetic
scale and actual-hardware browser checks remain release acceptance gates.
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
