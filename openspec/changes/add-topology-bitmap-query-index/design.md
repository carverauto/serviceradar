# Topology bitmap query index

## Current behavior and evidence

| Evidence in the repository | Consequence |
| --- | --- |
| `elixir/web-ng/native/god_view_nif/src/lib.rs`, `build_roaring_bitmaps` | Set members are enumerated snapshot row indexes, not persistent identities. |
| `elixir/web-ng/lib/serviceradar_web_ng/topology/god_view_stream.ex`, `encode_payload` and `build_bitmaps` | Serialized bitmaps are built but only byte counts reach the Arrow encoder. |
| `elixir/web-ng/assets/js/lib/god_view/rendering_graph_bitmap_methods.js` | Filtering uses a per-node mask and bitmap metadata is descriptive. |
| `elixir/web-ng/lib/serviceradar_web_ng/topology/world_tile.ex` | The current tile encoder sends zero bitmap byte lengths and builds geometry independently of the legacy snapshot. |
| `elixir/serviceradar_core/lib/serviceradar/inventory/endpoint_inventory_fleet_ordinal.ex` | A durable device UID-to-ordinal dictionary already exists, but allocation casts to signed PostgreSQL `integer`. |
| `elixir/serviceradar_core/lib/serviceradar/inventory/identity/endpoint_inventory_moves.ex` | Identity merging retains the survivor's ordinal and tombstones the losing ordinal. |
| `elixir/web-ng/lib/serviceradar_web_ng/topology/world_health.ex` | Bounded dirty IDs, one supervised task, generation fences and reconciliation already exist for availability. |
| `elixir/web-ng/lib/serviceradar_web_ng_web/controllers/topology_tile_controller.ex` | Tile access rechecks current `analytics.view` and `devices.view` authority before delivery. |

These are code observations, not performance results. The
[binary-path audit](../../../docs/topology-binary-path-audit.md) records remaining
JSON encodings, copies, tile budgets and unproven scale claims.

## 1. Identity is persistent; row position is local

Keep `ocsf_devices.uid` canonical. Reuse `platform.device_fleet_ordinals` for all
canonical devices, including endpoints already represented as devices. Do not
create a second device sequence or add derived ordinals to `ocsf_devices`.
Generalize the allocator behind a shared inventory owner while retaining the
endpoint inventory caller contract.

Preserve every assigned number. Migrate the dictionary column and sequence to
`bigint`, constrain IDs to `1..4294967295`, and retain uniqueness, foreign keys
and `NO CYCLE`. Reserve zero. Audit every consumer and remove signed narrowing
casts. Existing gaps, aborted allocations and tombstones are legal: the prior
spec's density goal means economical monotonically allocated IDs, never a
promise of contiguous indexes or permission to renumber them. Avoid consuming
sequence values on routine reads of already allocated identities.

Backfill missing active canonical devices by keyset pages. Cover all creation,
merge, delete and restore writers, including raw bulk upserts, rather than
relying only on endpoint inventory ingestion. Merges atomically transfer
membership to the canonical survivor and remove the losing ordinal; deletion
clears live membership without freeing the ID. A legitimate restore of the same
UID reuses its existing assignment. A merged-away identity cannot be restored
as an independent member through a stale event.

Each bitmap carries `(dictionary_epoch, entity_kind)`. Interface identities use
a separate dictionary over canonical `(device_uid, interface_uid)`, not an
interface sample timestamp or array offset. Interface-to-device projection is
explicit, current and authorized; device and interface sets cannot be ANDed
directly. An endpoint that lacks a canonical inventory entity is not silently
invented by this feature. Such a source needs its own identity contract before
joining an index. Aggregate glyphs, edge clips and bundles never consume
inventory IDs.

The dictionary epoch changes only for incompatible dictionary restoration or
replacement, not every layout or index rebuild. Process/index epochs fence
volatile rebuilds separately. Backups preserve the dictionary with inventory.
Cross-epoch data is rejected. Report capacity well before exhaustion and refuse
new assignments at the limit while keeping the accepted index readable. A
future 64-bit protocol requires explicit negotiation and migration.

## 2. A bounded, rebuildable Rust index

Add a native index resource in the topology engine and integrate its lifecycle
with the existing world/health owner. One serialized publisher admits batches;
readers pin an immutable revision while queries run on bounded dirty CPU work,
never an unbounded NIF on a normal BEAM scheduler. Structural sharing avoids
copying all indexes per update. Revision pins, concurrent readers and retired
revisions have byte/time caps; cancel slow readers before retiring resources.

Use current-state reads as truth. Dirty notifications contain IDs and act as
hints. Add durable, transactionally recorded dirty work for inventory attributes
and identity transitions, including raw upserts. Its consumer claims pending
rows, rereads current canonical data, publishes a complete native update, then
acknowledges work. A sequence maximum alone is not a commit-order watermark:
late commits and claimed-but-crashed rows must remain discoverable. Coalesce by
identity with a change token; acknowledge only the consumed token so a newer
change cannot be lost. A crash after native publication causes an idempotent
replay. Periodic keyset reconciliation repairs missed hints and reports age.

Seed with bounded current-state pages and drain the durable dirty work across
the scan boundary before announcing readiness. Deletions and merges must be
represented in dirty work even if the source row disappears. Publish one index
revision atomically, including live membership, attributes, availability and
source revision markers; never expose half-applied state changes. If a source
cannot provide a coherent current revision, report it as stale/unavailable and
do not return an apparently exact mixed-revision result. The accepted index
remains available while a replacement is prepared, with its freshness visible.

Initial admission limits are 500 IDs per read batch, 5,000 coalesced dirty IDs
and 512 KiB of pending hints, matching existing world-health bounds. Durable
overflow marks reconciliation required instead of retaining an unbounded BEAM
mailbox. Set explicit query deadlines, worker concurrency, native allocation and
replacement headroom budgets before rollout. Sustained overload rejects work
or delays freshness with a visible reason; it never silently loses changes.

## 3. Supported facets have explicit sources

| Facet or set | Source and semantics |
| --- | --- |
| Vendor, region, VLAN, device class | Canonical `Device.vendor_name`, `region`, `vlan_uid`, and normalized `type_id`/`type`. |
| OS name/version and tags | Allowlisted keys from canonical `Device.os` and `tags`; missing values have an explicit unknown bucket. No arbitrary JSON-path index creation. |
| Site and network role | Only a documented canonical source or configured tag mapping; role is not guessed from a device label or conflated with device class. Unsupported mappings are reported. |
| Availability | Existing current-state world-health source; healthy/unavailable/unknown. |
| Causal state | Existing authoritative causal output, independently revisioned; root cause/affected/healthy/unknown. Availability does not imply causal state. |
| Active alerts/incidents and impact | Existing authorized membership projections keyed by canonical device identity and source revision. No new causal evaluator or extension of the retiring central engine. |
| Search | Bounded, authorized search results materialized as an expiring set with its own source revision and completeness marker. Arbitrary SRQL is not translated speculatively into bitmap operators. |

The first release supports canonical inventory facets and availability. The
subsequent query phase adds the listed causal/alert/impact/search adapters only
when their source contracts and completeness tests pass; unsupported filters
fail explicitly rather than returning an empty or approximate exact result.
Tag/OS value count, key length and index bytes are capped. Exceeding a cap makes
that facet unavailable with a diagnostic, not a silent partial index.

## 4. Query, counts and authorization

Accept a bounded allowlisted expression tree: `all`, `any`, `except`, and exact
facet-value predicates. Normalize commutative operands and duplicate terms for
cache keys. Initial caps: 32 predicates, depth 8, 50 requested facet values, a
16 KiB control request, and a 1 second end-to-end server deadline. Return a
structured unsupported/budget/stale error; never fall back to a fleet scan in a
request handler. Small control requests may be JSON; bulk membership may not.

For a current authorized live universe `U`, evaluate `R = U & expression`.
Negation is `U ANDNOT excluded`, not complement over all possible integers.
Facet counts are **conjunctive**: `cardinality(R & facet_value)`, including
filters on that same facet. A future disjunctive UI needs an explicit separate
contract. Empty results are successful zero-cardinality sets.

Revalidate current RBAC on admission and immediately before delivery, including
304 responses, cached queries, facets, search, aggregate counts, details and
stream frames. The current deployment-wide permission model can yield all or
none of the live universe; finer device visibility is derived only from actual
policy. Do not add tenants, customer routing, bypass actors or a parallel policy
engine. Interface visibility also requires its parent device to be visible.
Revocation cancels outstanding work and clears client membership. Cache keys
include an authority fingerprint; authorization must never depend on a stale
bitmap surviving in a cache.

Query results are ordered by stable ordinal for pagination. Cursors bind the
normalized query, dictionary/index epochs, index revision, authority fingerprint,
entity kind and last ordinal. Tile/detail cursors additionally bind the current
world generation/layout revision. Revisions that have expired require restart,
not mixed pages. Existing detail limits remain: 128 devices, 256 relations and
at most 4,096 scanned candidates per request.

Hot-result caches store dependencies and changed-ID sets. On a relevant change,
re-evaluate affected IDs against the new consistent revision and patch the
cached result, or discard it. Changes to negated predicates, live universe,
identity, search completeness or authority count as dependencies. Unaffected
entries may be promoted only with proof that all dependency revisions are
unchanged. Cap total bytes, entry count, TTL and in-flight work; do not retain
one full result per viewer without charging it to the budget.

## 5. Query membership composes with the tiled world

The persistent ELK world defines positions and aggregate membership. A filter
changes visibility and counts, never parent links or layout coordinates. The
server intersects `R` with each admitted glyph's canonical membership. Aggregate
counts include authorized matching members only. Leaf state bitmaps contain
canonical device IDs; aggregates carry bounded count/state summaries keyed by
glyph ID rather than pretending to be devices. Relations require both endpoint
memberships or the existing authorized aggregate/bundle contract.

Zooming into a matching aggregate requests its next bounded tile/detail page.
It does not enumerate all matching endpoints in the browser. Preserve the
existing 128 glyphs, 512 edges and 256 KiB per tile, 64 admitted tiles, four fetches
and 32 MiB geometry cache limits. Membership has a separate 8 MiB resident
browser budget, including WASM heap, decoded sets, buffers and temporary staging;
it is not charged only by compressed wire size. On eviction remove associated
membership and cancel obsolete responses.

Geometry and membership have independent revisions. Each membership subscription
binds its query, authority and exact admitted tile receipts. Layout changes or
tile replacement invalidate that binding and require a fresh bounded baseline.
Geometry must not be rebuilt for a health tick. A bitmap resync must not discard
valid geometry. Until a matching baseline is installed, the client shows pending
filter state and does not render an unfiltered frame as a successful result.

## 6. Binary protocol and recovery

Negotiate a new versioned bitmap protocol alongside existing schema-3 Arrow
tiles. Use the standard portable 32-bit Roaring format, little endian, with
checked decoding and Rust-to-roaring-wasm interoperability tests. Do not send
native memory images, JSON ID arrays or base64 wrappers. Pin the browser codec
through the normal dependency/firewall and Bazel lock workflow at implementation
time. Format specification:
[RoaringFormatSpec](https://github.com/RoaringBitmap/RoaringFormatSpec);
browser implementation: [roaring-wasm](https://github.com/SalvatorePreviti/roaring-wasm).

The binary envelope contains protocol/codec version, dictionary and index
epochs, entity kind, query digest, authority fingerprint, admitted-view digest,
source/index revisions, base/next sequence, payload kind, and length-prefixed
named set sections. Revisions are opaque binary values or losslessly handled
integers, never unsafe JavaScript numbers. Counts and payload lengths are
checked before allocation. The negotiated state table explicitly maps the
current runtime codes `0=root_cause, 1=affected, 2=healthy, 3=unknown`; availability
uses its own named domain. The legacy specification has a different causal
ordering, so no consumer may infer these codes from old metadata.

The baseline contains actual bounded-view membership/state bitmaps. A delta
contains `previous XOR current` for every changed set plus bounded aggregate
summaries. Apply all sections atomically after validating the complete frame.
Exactly one causal state per admitted leaf is maintained, with unknown for
unavailable causal evidence. Duplicate sequence frames are ignored, gaps and
wrong epochs trigger a baseline reset, and late frames from evicted views are
discarded. XOR is not idempotent; duplicates must never be applied twice.

Cap each frame at 256 KiB, each connection at two pending frames and one
in-flight baseline, and total baseline assembly at the 8 MiB membership budget.
Large baselines are chunked with a transaction ID, total length and digest,
bounded chunk count, deadline and atomic completion. A partial baseline cannot
replace accepted membership. Coalesce slow-viewer changes against the last
acknowledged baseline; if history or byte limits are exceeded, send one reset
marker and stop deltas until a fresh bounded baseline is acknowledged. Reconnect
requires a valid retained base or a new baseline. These limits are correctness
bounds; the benchmark's 50 KB target is not a guarantee for arbitrary churn.

Decode membership in roaring-wasm and derive masks only for admitted leaf rows.
Retain their typed ID-to-row mapping. Arrow attributes remain typed columns and
are not routed through an additional whole-scene WASM copy just to use Roaring.
Document IPC decode, WASM ingress, mask packing and GPU upload allocations
separately. Portable WebGPU uploads are not an end-to-end zero-copy guarantee.
Queued GPU consumers must finish before their buffers are destroyed or replaced.

## 7. Rollout and rollback

1. **Dictionary and server index:** migrate/backfill without renumbering, enable
   bounded shadow indexing, test authorization and current-state parity, measure
   memory and query costs. Preserve the existing renderer.
2. **Server query/facets:** enable authorized filter/count/page APIs and tile
   membership projection. Complete each source adapter before exposing its
   predicate. Compare exact results against a synthetic reference evaluator.
3. **Browser deltas:** negotiate binary membership behind a feature flag, add
   roaring-wasm, retain the bounded legacy rendering path during rollout, then
   remove obsolete metadata-only claims once real usage is demonstrated.

Disabling the feature stops subscriptions and releases native/browser resources;
the old bounded tile view continues with an explicit unsupported-filter state
where necessary. Never silently broaden a filtered result. Rollback retains
the ordinal dictionary, tombstones and widened storage. No destructive ID reset,
automatic downgrade to signed integer, live cleanup, deployment or release is
part of this proposal.

## 8. Acceptance and measurements

All data is independently synthetic. The primary fixture contains 100,000
infrastructure devices plus 1,000,000 canonical endpoint devices. Run both
compact IDs and sparse IDs with merge/deletion gaps and values above `2^31`.
Declare seed, facet cardinalities/skew, query selectivity, churn distribution,
CPU/RAM, compiler flags, concurrency, sample count and warmup. Report p50/p95/p99,
peak memory and baseline results; do not substitute cached no-work operations.

| Measurement | Required target / interpretation |
| --- | --- |
| Four-term native AND/ANDNOT query | p95 < 5 ms; also report authorization and end-to-end latency separately. |
| Fifty exact conjunctive facet counts | p95 < 50 ms, same pinned result revision; include result computation. |
| One-percent state churn per tick | p95 < 50,000 serialized bytes summed across all changed state sets and envelope on the full synthetic population; report viewport payload separately. |
| Server index steady-state memory | < 200,000,000 bytes; include index-owned ID maps, facet sets, query caches and retained revisions. Exclude durable database pages and geometry, report them separately. |
| Rebuild and sustained churn | Report peak old+new index memory, convergence lag and backlog; enforce a separately configured peak cap and fail rollout if it is exceeded. |
| Browser | Prove the existing geometry caps plus 8 MiB membership cap using retained CPU/WASM/GPU accounting, repeated zoom/eviction/reconnect, and real-GPU frame timings. Software GPU results cannot certify hardware FPS. |

Compare the same operations and results with today's per-node array approach.
Exercise at least 100 concurrent synthetic view subscriptions with a slow
consumer group; report per-viewer memory and total fanout work. Test an
adversarial high-cardinality tag set, selective and broad queries, authority
revocation, missed notifications, publisher crashes, deletes/merges/restores,
baseline cancellation, sequence gaps/duplicates and malformed binary lengths.

Benchmarks and fixture provisioning are declared Bazel targets executed on
BuildBuddy. Unit, integration and browser layers own distinct contracts; avoid
source-text assertions. The README reports measured behavior and limitations,
not an unqualified carrier-grade or zero-copy claim.

## Alternatives and unresolved implementation choices

- A new device ID table would duplicate the existing merge-safe identity space;
  reuse is preferred, with an additive type namespace for interfaces.
- Shipping full-fleet bitmaps to every viewer simplifies client queries but
  violates bounded browser work and risks unauthorized membership disclosure.
- Roaring replaces query membership scans; it does not replace Arrow attributes
  or make GPU uploads free. Keep the two responsibilities separate.
- Specific canonical role/site and alert/impact adapters must be selected from
  actual source contracts during phase two. Until then their API predicates
  remain unsupported. This is an explicit rollout condition, not inferred data.
- The benchmark must establish realistic concurrency and rebuild headroom;
  the issue's steady-state targets are acceptance criteria, not evidence.
