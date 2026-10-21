# Exact filtered relation membership

## Existing owners and failure

`rust/topology-atlas/src/tiles.rs` owns glyph grouping, clipping and bundle
identity. `TileSelection` retains the accepted edge rows. Its
`rendered_edge` mapping and the spatial traversal in `World::tile_relations`
already connect canonical relations to rendered rows.

`BitmapView` projects node selectors through one authorized native query.
The SRMO v1 frame contains node counts but no relation counts.
`WorldTileLayer.relationShown` therefore requires complete endpoint populations.
The existing renderer test deliberately expects an edge width of zero for a
partially matched aggregate. The screenshots are consistent with this contract;
the connected Chrome session remains at sign-in, so no live reproduction is
claimed.

## Relation semantics

For every canonical relation represented by a displayed edge, count one match
only when both canonical device endpoints belong to the authorized query
result. Use the geometry owner's existing relation-to-row mapping, including
class, stale/current separation and clipping. Never infer a relation from two
positive aggregate counts. Parallel canonical relations retain their existing
multiplicity; clipped copies retain their tile-local identities.

Unknown endpoint ordinals do not match. An exact zero count means no matching
connection. A budget refusal or incomplete scan is an error, never an exact
zero or a partial count advertised as complete.

Shared boundary portals can carry an exact edge count when the underlying
relation endpoints are mapped, without assigning a device identity to the
portal. Boundary glyphs remain invisible and unpickable. Nodes, layout,
aggregate membership, and the authorized inventory total retain their owners.

## Bounded native projection

Extend the Atlas selection/ordinal boundary to expose bounded packed batches
of `(edge row, source ordinal, target ordinal)` from the existing spatial index.
The bitmap query owner evaluates both ordinals against its pinned authorized
result and returns row-aligned counts. BEAM orchestrates bounded binaries and
reduces count columns; it never expands aggregate populations or relation IDs
into whole-fleet object lists.

Reuse the existing candidate traversal and progress cursor. Each batch checks
world/selection/dictionary continuity. Empty batches must advance their cursor.
Keep the existing 4,096-candidate per native traversal bound, explicit byte and
allocation admission, and the shared membership request deadline. Record total
candidate work across the entire view with a 262,144-candidate ceiling, reserving
a full 4,096-candidate page before each call. This permits one maximum page for
each of the 64 admitted tiles; multi-page tiles share the same ceiling. Do not
restart the budget for every tile or spin through unbounded pages.

Accumulate at most 512 checked uint32 counts per tile and 64 tiles per view.
Only a completed projection publishes a replacement. World changes, revoked
authority, timeout, overflow or incomplete coverage discard the tentative
result. Existing retry and retained-view expiry govern recovery. Full endpoint
membership remains a safe optimization for a row whose complete population is
already proven, but cannot substitute for exact projection of a partial row.

Measure dense and sparse synthetic workloads before accepting this path. If
bounded traversal cannot meet the existing interaction deadline, revisit native
selection indexing explicitly; do not raise limits until a fleet scan fits.

The synthetic native projection measurement scanned 131,072 canonical candidates
in 272 pages with compact and sparse ordinals. It conserved all rendered relation
counts in both cases, took 29.57/26.12 ms, and returned at most 3,072 bytes per
page. This fixture has one rendered bundle (four accumulator bytes); it measures
Atlas selection/projection, not BEAM orchestration or concurrent request latency.
The shared request deadline remains the interaction bound. Evidence:
[BuildBuddy c0fcf50e](https://carverauto.buildbuddy.io/invocation/c0fcf50e-6e6b-4dfb-808d-76f6d9c5d66e).

## Wire contract and rolling updates

Advertise support for membership protocol 2. A client selects it only when the
server advertises it; servers continue accepting protocol 1. Bind the selected
protocol into the admitted view digest. Version 1 keeps its current bytes and
conservative behavior.

Version 2 retains existing metadata and node columns. After each tile's node
columns it appends a uint16 edge row count, then one little-endian uint32 matching
count for each geometry edge in exact Arrow order. Counts cannot exceed the
geometry edge's represented count. Reset frames retain their no-tile shape.
The decoder and membership admission validate version, exact row count,
revision, population, sequence and identity before publishing any tile.

Worst-case new count payload is 64 * 512 * 4 = 131,072 bytes, plus 128 bytes
of edge row counts. Existing node columns use 57,344 bytes. Together with
bounded metadata and receipts, the replacement must remain within 256 KiB.
Include backing buffers and aligned count copies in retained-memory accounting.
No browser relation-ID lists, bitmap engine, chunk assembly or query cache.

## Rendering and picking

Version-2 edges draw when their matching relation count is positive. Pending,
expired, mismatched, disabled-class and hidden edges remain unpickable. Version-1
membership retains the complete-endpoint fallback. Camera-only retained views
keep their node and edge columns together under the existing ten-second bound.

Filtered picks expose the matching count; the immutable geometry count remains
available internally for receipt and telemetry validation. Existing filtered
detail requests continue carrying the same query. Do not expose unfiltered
bundle members through newly pickable edges.

Structural visibility is separate from traffic eligibility. A partial matching
bundle can draw a line but cannot animate its full-bundle traffic. Whole-bundle
telemetry becomes eligible only if the matching relation count equals the
geometry count and all current freshness, class, selected-coverage and measured
rate rules also pass. This change does not estimate a filtered traffic rate.

## Validation ownership

- Native projection: exact canonical pairs, shared portals, parallel/class/stale
  separation, unmapped endpoints, cursor progress and work/memory limits.
- Protocol boundary: legacy and negotiated frames, malformed row counts,
  overflow, receipt and identity mismatch, and atomic admission.
- Real WebGPU: a synthetic mixed-vendor aggregate retains its actual matching
  connection across zoom levels; positive endpoint counts without a matching
  relation draw nothing. Partial bundles do not animate full-bundle traffic.
- Existing camera regressions: held replacement frames, delayed geometry and
  late old-view updates retain the same expiry and query-change behavior.

Observe the missing-edge regression fail before the implementation. Reuse
existing fixture builders and test owners; do not duplicate the same contract
at every layer. Run focused remote Bazel checks, `make test`, and no-mistakes
through all CI checks before publishing an implementation PR.
