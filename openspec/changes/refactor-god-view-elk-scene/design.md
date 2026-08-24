## Context
God-View currently has several geometry authorities:

1. `computeBackboneLayeredPositions` creates the normal `client-radial` backbone.
2. attachment satellites are positioned after that layout.
3. expanded cluster members are projected into one of several spiral candidates after that layout.
4. deck.gl draws direct source-to-target geometry independently of ELK route output.
5. camera fitting measures node centers and world-space radii, while labels and halos use fixed screen pixels.

This makes local invariants pass while the rendered composition fails. In the paired farm01 snapshots, expanding one 24-member endpoint cluster changes decoded graph nodes from 30 to 54 and attachment-class semantic edges from 24 to 48, while canonical semantic routes remain 32. The expanded summary remains a non-rendered gateway, so decoded graph counts are not rendered-glyph counts. The zero semantic-route delta is desirable, but the visual result becomes substantially worse because member geometry and labels are packed without one global layout or screen-space collision pass.

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

### Decision 1: Canonicalize semantic routes before layout
The semantic visible graph is converted into stable semantic-route entities before ELK runs. Each entity has one stable edge identifier, one canonical direction, and a sorted list of contributing semantic `relationIds`. Fanout manifolds may add physical rail and trunk strokes, but they do not add, remove, merge, or renumber these semantic routes. This makes the pipeline:

```text
bounded semantic graph
  -> canonical semantic routes
  -> compound nodes, direct ports, high-degree manifolds, and layout-only constraints
  -> one layered INCLUDE_CHILDREN ELK graph
  -> semantic branches plus decoded manifold rail/trunk paths
  -> deck.gl scene
```

Several semantic relations may contribute to one rendered entity, but no post-layout representative route is selected and no route is reversed after decoding. Direction is chosen only after all pair contributions are aggregated: if any contribution is attachment evidence and exactly one endpoint is an attachment satellite, direction is infrastructure to satellite; every other pair uses lexical endpoint order. Thus input row order cannot change ELK ports or geometry. Expansion changes semantic membership without multiplying visible cluster trunks.

The server-side input to this pipeline first preserves connectivity without restoring the redundant inferred-segment fanout fixed by PR #3937. The bounded projection admits up to 5,000 backbone rows, 2,000 inferred-segment candidates, and 2,000 ordinary attachment rows in deterministic class order; inferred candidates do not compete with ordinary attachments for one shared quota. After device lookup, guaranteed non-attachment transport edges seed a deterministic union-find. Inferred-segment rows then contribute only the stable total-order spanning forest still needed to connect those components. Retained bridges bypass endpoint-attachment collapse and are normalized to `INFERRED_TO` / `inferred` transport semantics with a backbone plane, raw relation/evidence provenance, and an explicit connectivity-bridge marker. Downstream projection cannot promote that marker back into an attachment. Shared attachments, single-identifier inference, and redundant inferred rows do not seed or survive this forest. Pipeline diagnostics retain the original pre-forest row count as `raw_links`; unique-pair and final-edge counts describe later stages so suppression remains observable instead of appearing as zero parity delta.

### Decision 2: ELK produces the complete compound scene
The ELK graph contains:

- root-level infrastructure and standalone nodes;
- one compound child node for each visible endpoint cluster;
- real glyph nodes whose minimum boxes remain `448x448` for a visible collapsed summary, `112x112` for a non-rendered expanded gateway, `96x96` for an expanded member, and `112x112` for an ordinary or anchor glyph;
- a direct deterministic flow-side port for each degree-one node endpoint role;
- one sibling zero-thickness rail and one auxiliary ELK-routed glyph trunk for each node endpoint role whose rendered degree is greater than one;
- pre-aggregated visible infrastructure and anchor-to-group relations; and
- layout-only gateway-to-member constraints that allocate internal space without rendering a fan of member spokes.

The profile uses layered layout, `INCLUDE_CHILDREN` compound handling, and orthogonal routing. Direction comes from a quantized usable-viewport profile: `RIGHT` for landscape and `DOWN` for portrait. Rendered endpoints are grouped by semantic node and canonical endpoint role, so source-role and target-role degree are evaluated separately. A role of degree one binds directly to one deterministic zero-size glyph port: sources use the profile's forward side (`EAST` or `SOUTH`) and targets use the opposite side (`WEST` or `NORTH`).

A role of degree `d > 1` gets exactly one fanout manifold under the glyph's compound owner. The manifold rail is a sibling ELK node with zero flow-axis thickness and `(d + 1) * 208` world units of cross-axis length. The `208` manifold slot is exactly twice the `104` world-unit ELK edge-node corridor, keeping a centered trunk clear of its nearest branch when degree is even. The glyph has one role port. The rail has one glyph-facing trunk port and one relation-facing branch port per semantic route, ordered by stable route identifier. One auxiliary ELK edge connects the glyph port to the trunk port; each semantic route binds to its own rail branch port. The real glyph box is never inflated by degree, and source-role and target-role fanout never share a rail. Layout-only packing constraints retain ELK's implicit ports and do not create manifolds or reserve visible-route capacity. Node and group sizes include obstacle padding, while fixed-pixel label collision remains a renderer step.

Glyphs, direct ports, sibling rails, trunks, semantic branches, compound groups, and layout-only constraints all enter the same ELK invocation. The decoded rail span comes only from the ELK-positioned zero-thickness rail and its ports. No later code moves a glyph or rail, synthesizes a different bend, or fans routes apart.

Expanded membership packing remains an ELK input constraint rather than a coordinate pass. The deterministic cross-axis chain count rounds the profile's aspect-shaped estimate upward, which avoids an unnecessarily long portrait flow axis while leaving every child position, compound bound, bend, and route section to the same ELK invocation.

All nodes, edges, children, and contributing-relation arrays are sorted by stable identifiers. ELK uses a fixed `elk.randomSeed`; determinism is required within tolerance for the pinned elkjs version, not across engine upgrades. The cache key includes structural graph identity, expansion set, and viewport profile. Input iteration order must not change the result.

Every relation is owned by the lowest common ELK compound containing both endpoints. A manifold rail is a sibling of its glyph in that same owner, and its trunk remains owner-local. Rendered member relations and non-rendered packing constraints whose endpoints are inside one expanded group live on that group; only relations that cross group boundaries remain on the root. This preserves ELK's coordinate-frame and hierarchy-routing contract instead of asking the root graph to lay out detached group-local edges.

Why not flat ELK plus a later group packer: it would retain two geometry authorities and allow endpoint groups to overwrite space that the backbone already occupied.

### Decision 3: Decode ELK once into a renderer-neutral scene
A new pure adapter owns the ELK boundary:

```text
buildElkSceneGraph(visibleGraph, viewportProfile) -> ElkNode
decodeElkScene(elkResult, edgeMetadata) -> TopologyScene
```

`TopologyScene` contains:

```text
nodes:          id -> {center, width, height, groupId, render}
groups:         id -> {bounds, memberIds, anchorId}
routes:         semanticRouteId -> {sourceId, targetId, points, relationIds, manifold junction ids}
manifolds:      manifoldId -> {nodeId, endpointRole, railPoints, trunkPoints, branch/trunk junctions, semanticRouteIds}
physicalRoutes: semantic branches plus one drawn rail and one drawn trunk per manifold
bounds: aggregate world-space scene bounds
```

The decoder first builds an absolute-offset map for every root, compound, glyph, port, and rail element. A glyph center is its absolute top-left plus half its width and height; a group retains its absolute top-left and size. Edge points are translated by the absolute offset of `edge.container`, falling back to the edge array owner's offset only when `container` is absent.

Every canonical semantic route remains one entry in `scene.routes`, whether it binds directly to a glyph or to a manifold branch port, so the semantic route count and relation identity contract do not change. Each semantic branch and each manifold trunk is a simple one-source/one-target ELK edge and MUST decode to exactly one continuous section: `startPoint`, ordered `bendPoints`, and `endPoint`. A branch or trunk with zero, multiple, branching, discontinuous, or fewer-than-two-distinct-point sections rejects the scene. Each manifold rail path is the ordered span of the rail's decoded zero-thickness axis through its trunk and sorted branch-port contacts; a disconnected or non-finite rail rejects the scene. Layout-only constraints are not drawn and are excluded from this assertion.

`scene.manifolds` records the rail, routed trunk, stable semantic-route membership, and declared junction identifiers. `scene.physicalRoutes` is the renderer and geometry-validator input: all semantic branches plus exactly one rail and one trunk for every manifold. Scene bounds are accumulated from nodes, groups, and every physical path. Decoding a zero-thickness rail into its ordered axis is part of interpreting the ELK result, not a second routing or coordinate pass.

The rest of God-View consumes `TopologyScene`; it does not recompute positions or replace semantic or manifold paths. A last-good scene is compatible only when its structural graph identity, expansion set, and viewport profile key exactly match the requested scene. ELK failure reuses that scene when available and otherwise shows a recoverable layout error. A newly prepared snapshot or viewport-profile scene is not accepted until its render/focus transaction succeeds; a render exception restores the previous graph, layout/profile metadata, camera, density, interaction, and rendered-frame state and exposes a recoverable render diagnostic. There is no second geometry algorithm.

### Decision 4: Expanded clusters preserve one visible transport trunk
Expansion changes decoded semantic membership, not the number of canonical semantic routes into the cluster. The scene graph uses one visible anchor-to-cluster gateway relation. Member relationships needed for ELK packing are layout-only unless a future diagnostic mode explicitly makes one visible. Any rail or trunk needed to draw high-degree fanout is auxiliary physical geometry associated with existing semantic routes, never another semantic relation.

This preserves the observed farm01 contract: expansion adds 24 endpoint-member nodes and 24 attachment-class semantic edges while the `scene.routes` delta remains zero.

### Decision 5: deck.gl renders decoded polylines
Transport mantle and crust layers consume `scene.physicalRoutes` point arrays through `PathLayer`: one path per canonical semantic branch plus one rail and one trunk per manifold. `scene.routes` stays the semantic identity and count surface; manifold paths retain the stable semantic route identifiers they serve. A second direct `ArcLayer` or line from the same endpoints must not render over a semantic branch or replace a manifold. Standard `PathLayer` cannot reproduce the current source-to-target gradient, so this change uses one deterministic dominant/status color per route. Gradient path styling is separate future work.

Bent-route traffic particles are disabled until their position can be sampled by cumulative path distance. Selection and hover use the same semantic branch and associated manifold paths as the visible stroke. Mantle and crust paths use rounded joints so their finite-width screen-space geometry is bounded by the capsule clearance oracle without changing ELK-authored branch, rail, or trunk geometry.

ELK is expected to produce obstacle-aware geometry, and the adapter validates rather than assumes that property. Every semantic branch, rail, and trunk participates. Intersection means positive intersection with an obstacle's open padded interior using the configured epsilon; boundary tangency is allowed. A direct branch or manifold trunk may contact its declared glyph only at boundary egress/ingress; re-entry through that glyph's open interior rejects the scene. A group is incident when a physical path's declared incident glyph is the group or any descendant, so an anchor-to-gateway path may enter its owning group. Layout-only edges are excluded.

Positive-length collinear overlap between distinct physical-path interiors rejects the scene. Proper crossings, T-contacts, and other zero-length contacts remain valid for arbitrary accepted graphs and count the physical-path pair as a diagnostic. A contact is exempt from the diagnostic only when both paths declare the same manifold junction identifier and the contact occurs at that decoded junction point; merely sharing a semantic node is not an exemption. Collinearity uses signed perpendicular distance and projected interval overlap in world units so the epsilon is scale-independent. Dense acceptance fixtures require zero unrelated contacts or crossings.

### Decision 6: Labels are decluttered in screen space
ELK cannot solve collisions for labels whose font size remains fixed while the camera zoom changes. After projecting scene anchors through the active view state, the renderer builds deterministic label boxes using measured text metrics where available and a conservative estimate in unit tests.

Candidates are ordered by selected/focused status, infrastructure/summary role, operational relevance, and stable node identifier. A label tries stable top, right, bottom, and left candidates around its owning glyph. Its own attachment region is allowed; non-owning glyphs, admitted labels, every semantic-branch and manifold rail/trunk stroke corridor, and UI safe areas are obstacles. Lower-priority labels are culled. A selected/focused label evicts lower-priority conflicts when a safe candidate exists. If fixed chrome blocks every candidate, the identity remains available in the details surface instead of violating the collision contract.

Existing zoom-tier label-count budgets remain an upper bound, and edge labels remain off in the shared overview. Label admission is recomputed for view-state changes without rerunning ELK.

### Decision 7: Fit the scene and focus the selected neighborhood
Fit and initial view include full-scene node and group boxes, every semantic-branch and manifold rail/trunk extent, projected glyph allowance, admitted labels, and safe-area insets measured from the controls, warning strip, details surface, status strip, and canvas. Safe-area membership is observed dynamically because LiveView may insert or remove warning/details chrome without resizing the canvas. Focus instead frames the selected group's complete neighborhood: owning group, anchor, semantic branches, relevant manifold rails/trunks, glyphs, and admitted neighborhood labels. Both use the same safe-rectangle coordinate convention.

Expansion preserves a user-locked camera. Otherwise it focuses the most recently selected group without collapsing earlier groups. Fit is the explicit action that frames the complete scene and all expanded groups.

Fit resolves the label/camera dependency with a bounded two-pass algorithm:

1. fit world nodes, groups, and all physical paths using safe insets plus conservative pixel-glyph allowance;
2. project candidates and admit labels;
3. refit once if admitted label extents exceed the safe rectangle; and
4. re-admit labels, culling optional labels that still fall outside.

Calling Fit again with unchanged scene and viewport inputs produces the same view state and label set within tolerance. Managed camera states validate projected glyph separation, finite-width physical-path clearance from every nonincident glyph, and finite-width separation for noncontact physical-path pairs. The renderer derives a minimum camera scale and intrinsic safe-rectangle width/height for each presentation density from the accepted scene's immutable branch, rail, and trunk geometry plus fixed-pixel extents. Fit and focus reject a density when containment cannot reach those bounds; manual zoom, user-locked scene replacement, and safe-area-only resize use the same scale and intrinsic-span contract. Safe-area feasibility is evaluated against the current measured rectangle rather than cached with scene geometry because LiveView chrome may change independently. Accepted unrelated point contacts/crossings remain governed by the path validator rather than an impossible zoom constraint. Paths that declare the same manifold junction may converge only at that decoded junction; a shared semantic node alone never expands the exemption over a path body. ELK obstacle boxes are conservatively sized for the minimum supported managed-view scale; if the bounded scene still cannot fit without collision, lower-priority members remain summarized by the upstream visible-member budget.

Managed views prefer the detail presentation and fall back to the overview presentation only when the accepted camera scale cannot support the detail extents. Overview caps ordinary and expanded-member outer radii at `10` CSS pixels, collapsed-summary outer radii at `20` CSS pixels, endpoint-anchor outer radii at `12` CSS pixels, and every semantic/manifold mantle/crust width at `10` CSS pixels. Detail physical-path width is capped at `12` CSS pixels. The selected density also chooses the existing label-candidate shape.

Managed visual density is presentation state, not geometry. It may cap glyph radii, physical-path stroke widths, and label candidates, but it MUST NOT change the semantic graph, ELK input glyph/rail geometry, decoded node/group coordinates, semantic branches, or manifold rail/trunk points, and it MUST NOT invoke a second layout or post-layout packing pass. Manual camera changes recompute the feasible presentation contract against the same accepted scene.

The usable viewport rectangle determines the profile and camera fit. Sizes stay in one of two buckets; crossing a bucket may rerun ELK, while ordinary camera changes and same-bucket resizes only recompute projection, labels, and fit.

### Decision 8: Initial constants and tolerances are explicit
The first implementation uses these named defaults so tests share one oracle:

- landscape profile at usable aspect ratio `>= 1.2`, `RIGHT` direction, target aspect `1.6`;
- portrait profile below `1.2`, `DOWN` direction, target aspect `0.75`;
- ELK node-box minima of `448x448` world units for visible collapsed endpoint summaries, `112x112` for the hidden expanded gateway, `96x96` for expanded members, and `112x112` for ordinary/anchor glyphs; the visible summary minimum remains deliberately larger because its fixed-pixel halo is the maximum managed-view obstacle;
- a deterministic zero-size flow-side glyph port for a degree-one endpoint role; for degree `d > 1`, exactly one sibling rail with zero flow-axis thickness and `(d + 1) * 208` world-unit cross-axis length, one glyph-to-rail ELK trunk, and one stable sorted branch port per semantic route; the `208` slot is twice the named `104` ELK edge-node corridor, source and target roles remain separate, and layout-only constraints use implicit ports;
- compound inner padding `48` world units, component spacing `96` world units, and ordinary non-endpoint node spacing between layers `96` world units;
- ELK cross-axis node-node spacing `112` world units and expanded endpoint-compound member spacing between layers `112` world units;
- ELK edge-node spacing `104` world units both generally and between layers;
- runtime nonincident physical-path clearance `96` world units, ELK edge-edge spacing `192` world units both generally and between layers, and intersection epsilon `0.01` world units; these are deliberately distinct from the `104` edge-node corridor and `208` manifold slot;
- overview outer-radius caps of `10` CSS pixels for ordinary/member glyphs, `20` for summaries, and `12` for anchors; managed physical-path width caps of `10` CSS pixels in overview and `12` in detail;
- label padding `4` CSS pixels;
- layout determinism tolerance `0.01` world units and browser projection tolerance `1` CSS pixel; and
- at most the two Fit passes described above.

Changing these defaults requires updating the named constants and their fixture assertions together.

### Decision 9: geometry assertions are the primary visual regression contract
Tests use sanitized paired decoded-input fixtures derived from the observed farm01 collapsed and expanded states. The fixture retains stable topology identity, labels, cluster metadata, relation classes, and graph counts, but no credentials, live telemetry, or precomputed layout coordinates.

Required browserless assertions include:

- collapsed decoded graph: 30 nodes, 34 semantic edges, 24 attachment-class edges, and 32 canonical `scene.routes` entries;
- expanded decoded graph: 54 nodes, 58 semantic edges, 48 attachment-class edges, 32 canonical `scene.routes` entries, exactly 24 new `endpoint-member` nodes, and a zero semantic-route delta;
- the expanded summary is a non-rendered gateway, with rendered-glyph counts asserted separately by the fixture manifest;
- one connected component with no unplaced or isolated nodes;
- deterministic node, group, semantic-branch, rail, trunk, and junction output after input reorder and collapse/re-expand;
- disjoint non-nested node boxes and compound group boxes;
- all expanded members contained within their group;
- one valid section per semantic branch and manifold trunk, plus one connected zero-thickness ELK rail spanning its declared trunk and sorted branch ports;
- every semantic branch, rail, and trunk avoids nonincident padded node and group interiors, while direct branches and manifold trunks contact a declared glyph boundary without re-entering its open interior;
- no positive-length collinear overlap between distinct physical-path interiors in any accepted scene, with unrelated point-contact or crossing path pairs counted as validation diagnostics and only shared declared manifold junction contact exempt;
- no unrelated positive crossing, T-junction, or collinear overlap between physical-path interiors in the browser acceptance fixtures;
- projected glyph boxes do not overlap in managed camera states;
- projected nonincident physical-path strokes do not overlap glyph boxes, and noncontact physical-path pairs remain separated, in managed camera states;
- managed density changes only presentation extents and leaves normalized ELK node, group, semantic-branch, rail, and trunk geometry unchanged;
- admitted labels do not intersect each other, non-owning protected glyphs, any drawn semantic/manifold stroke, or UI safe areas; and
- Fit is idempotent and contains the complete visual scene in the safe viewport.

The final browser calibration uses the concurrent-expansion `800x1000` portrait fixture. With the constants above it fits at scale `0.101023` against a required floor of `0.098214`, leaving positive projected clearance margins of `0.629` CSS pixels for ordinary/anchor glyphs, `1.013` CSS pixels for expanded members, and `0.507` CSS pixels for physical-route strokes. These measurements are pinned acceptance evidence for the named spacing domains; changing the constants requires updating the fixture assertions and measured evidence together.

The fixture manifest pins local shape, topology-layer settings, visibility mask, aggregation policy, Chromium version, CSS viewport, DPR, production-font readiness, reduced motion, and disabled animation.

The Vitest fixture suite is owned by a Bazel unit target with fixtures declared as data so it participates in the normal unit sweep. The Playwright harness is a Bazel-owned `acceptance_test` target with an explicit CI invocation and screenshot/trace upload.

Playwright uses the real Deck/WebGL surface and production font metrics. It asserts exported geometry invariants and captures screenshots for human review. Pixel comparison is secondary because antialiasing and GPU differences do not prove geometry correctness.

## Risks / Trade-offs
- Compound ELK layout may cost more than the custom radial path.
  - Mitigation: the visible graph and member caps are bounded, layout inputs are cached by stable keys, and camera/label changes do not rerun layout.
- Native one-call portrait packing does not provide a safe escape hatch for this compound graph.
  - `SEPARATE_CHILDREN`, box, and rectpacking variants produced only 30 of 32 semantic route sections when relations crossed child containers. `INCLUDE_CHILDREN` preserved all 32 routes but absorbed child direction into the global layered layout and initially remained below the required portrait scale. Built-in wrapping, alternative layering, and deterministic reverse constraints also remained below the required scale. These alternatives were rejected instead of accepting route loss, fixture-specific coordinates, or a second geometry authority; direct degree-one ports, ELK-native high-degree manifolds, aspect-shaped packing constraints, and managed presentation density make the accepted one-call ELK scene feasible without moving it afterward.
- ELK compound routing can produce unexpected section coordinate frames or invalid sections.
  - Mitigation: isolate coordinate decoding and validation in a pure adapter and reject invalid scenes.
- Orthogonal routes can look mechanical or include more bends.
  - Mitigation: prioritize legibility and clearance; tune presentation only after invariants pass.
- Label measurement can differ across browsers.
  - Mitigation: use conservative padding and validate with production fonts in browser acceptance.
- An ELK failure can leave a new structural graph without geometry.
  - Mitigation: preserve only an exactly compatible last-good scene and otherwise show an explicit recoverable error; accept prepared snapshot/profile state only after rendering succeeds and restore the complete last-good presentation transaction on failure.

## Migration Plan
1. Amend `fix-topology-islands-and-cluster-expansion` with layout-engine-neutral placement requirements; archive it before this change during the post-deployment archive workflow.
2. Add paired fixtures and failing scene-contract tests.
3. Introduce pre-layout route aggregation and the pure compound ELK builder/decoder.
4. Switch normal orchestration to the decoded scene and remove satellite/spiral/fallback geometry.
5. Render decoded semantic branches and manifold rail/trunk paths through deck.gl path layers.
6. Add screen-space label decluttering and bounded visual camera fitting.
7. Add Bazel-owned unit and browser geometry acceptance.
8. Roll the fixed build to demo and compare collapsed plus expanded farm01 states before merging.

Rollback reverts the client implementation as one code change. Runtime switching between old and new geometry authorities is intentionally unsupported.

## Open Questions
- Should a selected member expose its otherwise layout-only attachment as a temporary diagnostic route?
