## Context
God-View currently has several geometry authorities:

1. `computeBackboneLayeredPositions` creates the normal `client-radial` backbone.
2. attachment satellites are positioned after that layout.
3. expanded cluster members are projected into one of several spiral candidates after that layout.
4. deck.gl draws direct source-to-target geometry independently of ELK route output.
5. camera fitting measures node centers and world-space radii, while labels and halos use fixed screen pixels.

This makes local invariants pass while the rendered composition fails. In the paired farm01 snapshots, expanding one 24-member endpoint cluster changes decoded graph nodes from 30 to 54 and attachment-class semantic edges from 24 to 48, while rendered routes remain 32. The expanded summary remains a non-rendered gateway, so decoded graph counts are not rendered-glyph counts. The zero rendered-route delta is desirable, but the visual result becomes substantially worse because member geometry and labels are packed without one global layout or screen-space collision pass.

ELK 0.11.1 is already installed and configured in the client. The missing work is not selecting another algorithm; it is treating ELK's complete graph result as the scene contract.

## Goals / Non-Goals

### Goals
- Use one deterministic layout invocation for the complete bounded visible graph.
- Give endpoint clusters explicit spatial containment and padding.
- Route rendered relations around nonincident nodes and groups.
- Keep glyphs and labels legible in managed initial, Fit, and focus views.
- Make expansion, collapse, camera operations, and viewport profiles stable.
- Prove the behavior using semantic fixture counts plus geometric invariants.

### Non-Goals
- Repair or reinterpret topology evidence upstream of the decoded client graph.
- Display every endpoint in high-fanout environments.
- Promise an aesthetically identical scene across different ELK versions.
- Treat pixel snapshots as the sole acceptance test.
- Render animated traffic particles along a bent path before path-distance sampling exists.

## Decisions

### Decision 1: Canonicalize rendered relations before layout
The semantic visible graph is converted into the exact rendered-route entities deck.gl will draw before ELK runs. Each entity has one stable edge identifier, one canonical direction, and a sorted list of contributing semantic `relationIds`. This makes the pipeline:

```text
bounded semantic graph
  -> canonical rendered relations
  -> compound nodes plus layout-only constraints
  -> one ELK graph
  -> one decoded route per rendered relation
  -> deck.gl scene
```

Several semantic relations may contribute to one rendered entity, but no post-layout representative route is selected and no route is reversed after decoding. Expansion changes semantic membership without multiplying visible cluster trunks.

### Decision 2: ELK produces the complete compound scene
The ELK graph contains:

- root-level infrastructure and standalone nodes;
- one compound child node for each visible endpoint cluster;
- a non-rendered summary/gateway node and expanded member nodes inside the group;
- pre-aggregated visible infrastructure and anchor-to-group relations; and
- layout-only gateway-to-member constraints that allocate internal space without rendering a fan of member spokes.

The profile uses layered layout, compound-child handling, and orthogonal routing. Direction comes from a quantized usable-viewport profile: `RIGHT` for landscape and `DOWN` for portrait. Node and group sizes include obstacle padding, while fixed-pixel label collision remains a renderer step.

All nodes, edges, children, and contributing-relation arrays are sorted by stable identifiers. ELK uses a fixed `elk.randomSeed`; determinism is required within tolerance for the pinned elkjs version, not across engine upgrades. The cache key includes structural graph identity, expansion set, and viewport profile. Input iteration order must not change the result.

Why not flat ELK plus a later group packer: it would retain two geometry authorities and allow endpoint groups to overwrite space that the backbone already occupied.

### Decision 3: Decode ELK once into a renderer-neutral scene
A new pure adapter owns the ELK boundary:

```text
buildElkSceneGraph(visibleGraph, viewportProfile) -> ElkNode
decodeElkScene(elkResult, edgeMetadata) -> TopologyScene
```

`TopologyScene` contains:

```text
nodes:  id -> {center, width, height, groupId, render}
groups: id -> {bounds, memberIds, anchorId}
routes: edgeId -> {sourceId, targetId, points, relationIds}
bounds: aggregate world-space scene bounds
```

The decoder first builds an absolute-offset map for every root and compound node. A node center is its absolute top-left plus half its width and height; a group retains its absolute top-left and size. Edge points are translated by the absolute offset of `edge.container`, falling back to the edge array owner's offset only when `container` is absent.

Every rendered relation is a simple one-source/one-target ELK edge and MUST decode to exactly one continuous section. Its route is `startPoint`, ordered `bendPoints`, and `endPoint`. A rendered edge with zero, multiple, branching, discontinuous, or fewer-than-two-distinct-point sections rejects the scene. Layout-only constraints are not rendered and are excluded from this assertion.

The rest of God-View consumes `TopologyScene`; it does not recompute positions or replace routes. A last-good scene is compatible only when its structural graph identity, expansion set, and viewport profile key exactly match the requested scene. ELK failure reuses that scene when available and otherwise shows a recoverable layout error. There is no second geometry algorithm.

### Decision 4: Expanded clusters preserve one visible transport trunk
Expansion changes decoded semantic membership, not the number of rendered transport paths into the cluster. The scene graph uses one visible anchor-to-cluster gateway relation. Member relationships needed for ELK packing are layout-only unless a future diagnostic mode explicitly makes one visible.

This preserves the observed farm01 contract: expansion adds 24 endpoint-member nodes and 24 attachment-class semantic edges while the rendered-route delta remains zero.

### Decision 5: deck.gl renders decoded polylines
Transport mantle and crust layers consume route point arrays through `PathLayer`. A second direct `ArcLayer` or line from the same endpoints must not render over a routed relation. Standard `PathLayer` cannot reproduce the current source-to-target gradient, so this change uses one deterministic dominant/status color per route. Gradient path styling is separate future work.

Bent-route traffic particles are disabled until their position can be sampled by cumulative path distance. Selection and hover use the same route geometry as the visible stroke. Mantle and crust paths use rounded joints so their finite-width screen-space geometry is bounded by the capsule clearance oracle without changing ELK-authored centerlines.

ELK is expected to produce obstacle-aware geometry, and the adapter validates rather than assumes that property. Intersection means positive intersection with an obstacle's open padded interior using the configured epsilon; boundary tangency is allowed. A group is incident when a route endpoint is the group or any descendant, so an anchor-to-gateway trunk may enter its owning group. Layout-only edges are excluded. The hard rendered-clearance contract applies to supported managed Fit/focus profiles; arbitrary user zoom-out cannot preserve pixel-halo clearance while glyphs remain fixed-size. Edge-to-edge crossings remain an optimization target and telemetry signal, not an absolute invariant.

### Decision 6: Labels are decluttered in screen space
ELK cannot solve collisions for labels whose font size remains fixed while the camera zoom changes. After projecting scene anchors through the active view state, the renderer builds deterministic label boxes using measured text metrics where available and a conservative estimate in unit tests.

Candidates are ordered by selected/focused status, infrastructure/summary role, operational relevance, and stable node identifier. A label tries stable top, right, bottom, and left candidates around its owning glyph. Its own attachment region is allowed; non-owning glyphs, admitted labels, routed stroke corridors, and UI safe areas are obstacles. Lower-priority labels are culled. A selected/focused label evicts lower-priority conflicts when a safe candidate exists. If fixed chrome blocks every candidate, the identity remains available in the details surface instead of violating the collision contract.

Existing zoom-tier label-count budgets remain an upper bound, and edge labels remain off in the shared overview. Label admission is recomputed for view-state changes without rerunning ELK.

### Decision 7: Fit the scene and focus the selected neighborhood
Fit and initial view include full-scene node and group boxes, route extents, projected glyph allowance, admitted labels, and safe-area insets measured from the controls, status strip, and canvas. Focus instead frames the selected group's complete neighborhood: owning group, anchor, trunk, glyphs, and admitted neighborhood labels. Both use the same safe-rectangle coordinate convention.

Expansion preserves a user-locked camera. Otherwise it focuses the most recently selected group without collapsing earlier groups. Fit is the explicit action that frames the complete scene and all expanded groups.

Fit resolves the label/camera dependency with a bounded two-pass algorithm:

1. fit world nodes, groups, and routes using safe insets plus conservative pixel-glyph allowance;
2. project candidates and admit labels;
3. refit once if admitted label extents exceed the safe rectangle; and
4. re-admit labels, culling optional labels that still fall outside.

Calling Fit again with unchanged scene and viewport inputs produces the same view state and label set within tolerance. Managed camera states validate projected glyph separation. ELK obstacle boxes are conservatively sized for the minimum supported managed-view scale; if the bounded scene still cannot fit without glyph collision, lower-priority members remain summarized by the upstream visible-member budget.

The usable viewport rectangle determines the profile and camera fit. Sizes stay in one of two buckets; crossing a bucket may rerun ELK, while ordinary camera changes and same-bucket resizes only recompute projection, labels, and fit.

### Decision 8: Initial constants and tolerances are explicit
The first implementation uses these named defaults so tests share one oracle:

- landscape profile at usable aspect ratio `>= 1.2`, `RIGHT` direction, target aspect `1.6`;
- portrait profile below `1.2`, `DOWN` direction, target aspect `0.75`;
- ELK node boxes `448x448` world units for endpoint summaries, `96x96` for expanded members, and `112x112` for other visible glyphs; the summary envelope is deliberately larger because its fixed-pixel halo is the maximum managed-view obstacle;
- compound inner padding `48` world units and sibling group separation `96` world units;
- route-to-node clearance `96` world units, route-to-route spacing `192` world units, and intersection epsilon `0.01` world units;
- label padding `4` CSS pixels;
- layout determinism tolerance `0.01` world units and browser projection tolerance `1` CSS pixel; and
- at most the two Fit passes described above.

Changing these defaults requires updating the named constants and their fixture assertions together.

### Decision 9: geometry assertions are the primary visual regression contract
Tests use sanitized paired decoded-input fixtures derived from the observed farm01 collapsed and expanded states. The fixture retains stable topology identity, labels, cluster metadata, relation classes, and graph counts, but no credentials, live telemetry, or precomputed layout coordinates.

Required browserless assertions include:

- collapsed decoded graph: 30 nodes, 34 semantic edges, 24 attachment-class edges, and 32 rendered routes;
- expanded decoded graph: 54 nodes, 58 semantic edges, 48 attachment-class edges, 32 rendered routes, exactly 24 new `endpoint-member` nodes, and a zero rendered-route delta;
- the expanded summary is a non-rendered gateway, with rendered-glyph counts asserted separately by the fixture manifest;
- one connected component with no unplaced or isolated nodes;
- deterministic output after input reorder and collapse/re-expand;
- disjoint non-nested node boxes and compound group boxes;
- all expanded members contained within their group;
- one valid section per rendered relation with no positive intersection against a nonincident padded node or group interior;
- no positive crossing, T-junction, or collinear overlap between nonincident rendered-route interiors in the browser acceptance fixtures;
- projected glyph boxes do not overlap in managed camera states;
- admitted labels do not intersect each other, non-owning protected glyphs, routed strokes, or UI safe areas; and
- Fit is idempotent and contains the complete visual scene in the safe viewport.

The fixture manifest pins local shape, topology-layer settings, visibility mask, aggregation policy, Chromium version, CSS viewport, DPR, production-font readiness, reduced motion, and disabled animation.

The Vitest fixture suite is owned by a Bazel unit target with fixtures declared as data so it participates in the normal unit sweep. The Playwright harness is a Bazel-owned `acceptance_test` target with an explicit CI invocation and screenshot/trace upload.

Playwright uses the real Deck/WebGL surface and production font metrics. It asserts exported geometry invariants and captures screenshots for human review. Pixel comparison is secondary because antialiasing and GPU differences do not prove geometry correctness.

## Risks / Trade-offs
- Compound ELK layout may cost more than the custom radial path.
  - Mitigation: the visible graph and member caps are bounded, layout inputs are cached by stable keys, and camera/label changes do not rerun layout.
- ELK compound routing can produce unexpected section coordinate frames or invalid sections.
  - Mitigation: isolate coordinate decoding and validation in a pure adapter and reject invalid scenes.
- Orthogonal routes can look mechanical or include more bends.
  - Mitigation: prioritize legibility and clearance; tune presentation only after invariants pass.
- Label measurement can differ across browsers.
  - Mitigation: use conservative padding and validate with production fonts in browser acceptance.
- An ELK failure can leave a new structural graph without geometry.
  - Mitigation: preserve only an exactly compatible last-good scene and otherwise show an explicit recoverable error.

## Migration Plan
1. Amend `fix-topology-islands-and-cluster-expansion` with layout-engine-neutral placement requirements; archive it before this change during the post-deployment archive workflow.
2. Add paired fixtures and failing scene-contract tests.
3. Introduce pre-layout route aggregation and the pure compound ELK builder/decoder.
4. Switch normal orchestration to the decoded scene and remove satellite/spiral/fallback geometry.
5. Render decoded routes through deck.gl path layers.
6. Add screen-space label decluttering and bounded visual camera fitting.
7. Add Bazel-owned unit and browser geometry acceptance.
8. Roll the fixed build to demo and compare collapsed plus expanded farm01 states before merging.

Rollback reverts the client implementation as one code change. Runtime switching between old and new geometry authorities is intentionally unsupported.

## Open Questions
- Should a selected member expose its otherwise layout-only attachment as a temporary diagnostic route?
