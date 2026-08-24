# God-View ELK Scene Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace God-View's radial/spiral/direct-edge composition with one deterministic compound ELK scene whose nodes, groups, routes, labels, and managed camera views satisfy executable collision and stability invariants.

**Architecture:** A pure semantic adapter canonicalizes the bounded decoded graph into rendered relations and compound endpoint groups before layout. A pure ELK adapter builds one graph and decodes absolute nodes, groups, and routes into `graph._topologyScene`; rendering, labels, and camera code consume that scene without authoring new geometry. Tests progress from exact semantic fixtures to real ELK geometry, deck.gl layer contracts, screen-space collision logic, and browser acceptance.

**Tech Stack:** JavaScript ES modules, elkjs 0.11.1, deck.gl 9.2 `PathLayer`, Vitest 3.2, Bazel `aspect_rules_js`, Phoenix web-ng, Playwright CLI/browser acceptance.

**Spec:** `openspec/changes/refactor-god-view-elk-scene/design.md` and `openspec/changes/refactor-god-view-elk-scene/specs/topology-god-view/spec.md`

## Global Constraints

- Work only in `/tmp/serviceradar-topology-elk` on `codex/fix-topology-elk-scene`; never push directly to `staging` and never use an implicit git push refspec.
- No production code is written before its covering test has been observed failing for the expected missing behavior.
- ELK is the only geometry engine: no radial, spiral, lane, grid, backend-coordinate, or alternate fallback layout may run after or instead of an accepted ELK scene.
- Canonical rendered relations are built before ELK; the farm01-style fixture contract is `30/34/24/32 -> 54/58/48/32` for decoded nodes/semantic edges/attachment-class edges/rendered routes.
- Expanded summaries are visible glyphs while collapsed and non-rendered gateways while expanded; expansion adds exactly 24 `endpoint-member` nodes and does not change rendered-route count.
- Rendered ELK edges are simple one-source/one-target edges and must decode to exactly one continuous section with at least two distinct points.
- Landscape profile: usable aspect `>= 1.2`, `RIGHT`, target aspect `1.6`; portrait: below `1.2`, `DOWN`, target aspect `0.75`; ELK uses a fixed random seed.
- Node boxes: endpoint summaries `448x448`, expanded members `96x96`, other glyphs `112x112`; compound padding `48`; sibling group separation and route-to-node clearance `96`; route-to-route spacing `192`; intersection epsilon `0.01`, all world units. Routed PathLayer joints are rounded so the rendered stroke matches the capsule clearance oracle.
- Label padding is `4` CSS pixels; layout tolerance is `0.01` world units; browser tolerance is `1` CSS pixel; Fit performs at most two passes.
- Existing visible-member limits and zoom-tier label budgets remain authoritative upper bounds; edge labels stay suppressed in the overview.
- Standard `PathLayer` uses one deterministic dominant/status color per route; bent-route particles are disabled until path-distance sampling exists.
- Preserve user changes and unrelated files; use `apply_patch` for tracked file edits.
- Before any Bazel command, verify `.bazelrc.remote` exists in the worktree. Do not read generated Bazel output.

---

### Task 1: Farm01 Semantic Scene Contract

**Files:**
- Create: `elixir/web-ng/assets/js/lib/god_view/fixtures/farm01_topology_regression.js`
- Create: `elixir/web-ng/assets/js/lib/god_view/topology_scene_graph.js`
- Create: `elixir/web-ng/assets/js/lib/god_view/topology_scene_graph.test.js`
- Test: `elixir/web-ng/assets/js/lib/god_view/rendering_graph_data_methods.test.js`

**Interfaces:**
- Produces: `prepareTopologySceneInput(graph)` returning `{nodes, groups, renderedRelations, layoutRelations, graphKey, manifest}`.
- Produces: `canonicalRenderedRelationId(sourceId, targetId)` and stable `relationIds` arrays.
- Produces: fixture exports `collapsedFarm01Graph()`, `expandedFarm01Graph()`, `reverseGraphArrays(graph)`, and `FARM01_EXPECTED`.
- Consumes: decoded local graph nodes with numeric edge endpoints and existing `details.cluster_*` metadata.

- [ ] **Step 1: Add the paired decoded-input fixture**

Create deterministic fixture generators with 30 base nodes: six connected infrastructure nodes, six endpoint summaries, and eighteen connected attachment nodes. Create ten backbone-class semantic edges containing two reverse-direction duplicate pairs and 24 attachment-class edges, for 34 semantic edges and 32 canonical rendered pairs. The expanded generator adds 24 `endpoint-member` nodes and 24 attachment-class member-to-anchor relations for 54 nodes and 58 edges. Mark one summary and all added members with the same expanded `cluster_id`.

```js
export const FARM01_EXPECTED = Object.freeze({
  collapsed: {nodes: 30, semanticEdges: 34, attachmentEdges: 24, renderedRoutes: 32, renderedGlyphs: 30},
  expanded: {nodes: 54, semanticEdges: 58, attachmentEdges: 48, renderedRoutes: 32, renderedGlyphs: 53},
  addedMemberCount: 24,
})
```

- [ ] **Step 2: Write failing manifest and canonicalization tests**

```js
it("preserves the farm01 expansion semantic delta without adding rendered routes", () => {
  const collapsed = prepareTopologySceneInput(collapsedFarm01Graph())
  const expanded = prepareTopologySceneInput(expandedFarm01Graph())

  expect(collapsed.manifest).toMatchObject(FARM01_EXPECTED.collapsed)
  expect(expanded.manifest).toMatchObject(FARM01_EXPECTED.expanded)
  expect(expanded.nodes.filter((node) => node.kind === "endpoint-member")).toHaveLength(24)
  expect(expanded.renderedRelations).toHaveLength(collapsed.renderedRelations.length)
})

it("canonicalizes relation identity independently of input order", () => {
  const forward = prepareTopologySceneInput(expandedFarm01Graph())
  const shuffled = prepareTopologySceneInput(reverseGraphArrays(expandedFarm01Graph()))
  expect(shuffled).toEqual(forward)
})
```

- [ ] **Step 3: Run the focused tests and verify RED**

Run: `cd elixir/web-ng/assets && bunx vitest run js/lib/god_view/topology_scene_graph.test.js`

Expected: FAIL because `topology_scene_graph.js` and its exports do not exist.

- [ ] **Step 4: Implement the minimal pure semantic adapter**

Implement stable graph-index-to-id resolution, expanded-group discovery, collapsed-summary render flags, pre-layout undirected pair aggregation, sorted contributing relation IDs, and synthesized gateway-to-member layout-only relations. Use edge IDs when present and a deterministic semantic signature otherwise. Do not read renderer state or assign coordinates.

```js
export function prepareTopologySceneInput(graph) {
  return {
    nodes: sortedSceneNodes,
    groups: sortedGroups,
    renderedRelations: sortedRenderedRelations,
    layoutRelations: sortedLayoutRelations,
    graphKey: stableGraphKey,
    manifest: sceneManifest,
  }
}
```

- [ ] **Step 5: Verify GREEN and protect the old render contract**

Run: `cd elixir/web-ng/assets && bunx vitest run js/lib/god_view/topology_scene_graph.test.js js/lib/god_view/rendering_graph_data_methods.test.js`

Expected: all tests pass; existing duplicate-pair and single-expanded-trunk tests remain green.

- [ ] **Step 6: Commit the semantic scene boundary**

```bash
git add elixir/web-ng/assets/js/lib/god_view/fixtures/farm01_topology_regression.js elixir/web-ng/assets/js/lib/god_view/topology_scene_graph.js elixir/web-ng/assets/js/lib/god_view/topology_scene_graph.test.js
git commit -m "test(topology): define farm01 ELK scene contract"
```

### Task 2: Compound ELK Builder, Decoder, and Orchestration

**Files:**
- Create: `elixir/web-ng/assets/js/lib/god_view/layout_elk_scene.js`
- Create: `elixir/web-ng/assets/js/lib/god_view/layout_elk_scene.test.js`
- Modify: `elixir/web-ng/assets/js/lib/god_view/layout_topology_state_methods.js`
- Modify: `elixir/web-ng/assets/js/lib/god_view/layout_topology_state_methods.test.js`
- Modify: `elixir/web-ng/assets/js/lib/god_view/lifecycle_bootstrap_state_defaults_methods.js`

**Interfaces:**
- Consumes: Task 1 `prepareTopologySceneInput(graph)` output.
- Produces: `viewportProfileForSize(width, height, safeInsets)`.
- Produces: `buildElkSceneGraph(sceneInput, profile)`.
- Produces: `decodeElkScene(elkResult, sceneInput)` returning `{nodes, groups, routes, bounds}`, where `nodes` is an array of `{id, center: {x, y}, width, height, groupId, render}`, `groups` is an array of `{id, bounds: {minX, minY, maxX, maxY}, memberIds, anchorId, gatewayId}`, `routes` is an array of `{id, sourceId, targetId, points, relationIds, metadata}`, and `bounds` is `{minX, minY, maxX, maxY}`.
- Produces: `validateTopologyScene(scene)` returning `{ok, errors}`.
- Produces: `layoutTopologyScene(sceneInput, {engine, profile})`.
- Produces: `applyTopologySceneToGraph(graph, scene)` returning a graph whose node `x/y` fields match scene centers and whose `_topologyScene` is the accepted scene.
- Produces: laid-out graph field `_topologyScene` and `_layoutMode: "elk-scene"`.

- [ ] **Step 1: Write failing builder and coordinate-frame tests**

```js
it("builds expanded endpoint membership as one compound ELK group", () => {
  const input = prepareTopologySceneInput(expandedFarm01Graph())
  const elkGraph = buildElkSceneGraph(input, LANDSCAPE_PROFILE)
  const expandedGroup = input.groups.find((group) => group.expanded)
  const group = findElkNode(elkGraph, expandedGroup.id)
  expect(group.children.map((child) => child.id)).toContain(expandedGroup.gatewayId)
  expect(group.children.filter((child) => child.layoutOptions?.["serviceradar.kind"] === "endpoint-member")).toHaveLength(24)
  expect(elkGraph.edges.filter((edge) => edge.layoutOptions?.["serviceradar.render"] !== "false")).toHaveLength(32)
})

it("decodes edge section points from edge.container coordinates", () => {
  const decoded = decodeElkScene(containerRelativeElkResult(), containerRelativeSceneInput())
  expect(decoded.nodes.find((node) => node.id === "gateway").center).toEqual({x: 245, y: 155})
  expect(decoded.routes.find((route) => route.id === "trunk").points).toEqual([{x: 100, y: 40}, {x: 180, y: 40}, {x: 220, y: 140}])
})
```

- [ ] **Step 2: Run the adapter tests and verify RED**

Run: `cd elixir/web-ng/assets && bunx vitest run js/lib/god_view/layout_elk_scene.test.js`

Expected: FAIL because the ELK scene adapter does not exist.

- [ ] **Step 3: Implement constants, builder, decoder, and validation**

Use the exact Global Constraints. Build root and compound options with `elk.algorithm=layered`, `elk.hierarchyHandling=INCLUDE_CHILDREN`, `elk.edgeRouting=ORTHOGONAL`, fixed seed, explicit node/group spacing, and stable child/edge order. Decode node centers separately from group bounds. Resolve edge section offsets from `edge.container`. Reject non-finite geometry, invalid section counts, overlapping non-nested boxes, members outside groups, and route intersections with nonincident padded interiors.

- [ ] **Step 4: Add a real-ELK failing integration test**

```js
it("lays out both farm01 fixtures deterministically with valid groups and routes", async () => {
  for (const graph of [collapsedFarm01Graph(), expandedFarm01Graph()]) {
    const input = prepareTopologySceneInput(graph)
    const first = await layoutTopologyScene(input, {engine: new ELK(), profile: LANDSCAPE_PROFILE})
    const second = await layoutTopologyScene(prepareTopologySceneInput(reverseGraphArrays(graph)), {engine: new ELK(), profile: LANDSCAPE_PROFILE})
    expect(validateTopologyScene(first)).toEqual({ok: true, errors: []})
    expect(normalizeScene(second)).toEqual(normalizeScene(first))
  }
})
```

Run: `cd elixir/web-ng/assets && bunx vitest run js/lib/god_view/layout_elk_scene.test.js`

Expected: FAIL until ELK options, group dimensions, and absolute section decoding satisfy the fixture.

- [ ] **Step 5: Wire the adapter into layout orchestration**

Replace the `client-radial`-first branch in `computeClientTopologyLayout` with `prepareTopologySceneInput` plus `layoutTopologyScene`. Apply decoded centers to graph nodes and attach `_topologyScene`. Extend the cache key with `graphKey` and viewport profile. Reuse a prior scene only for the exact cache key; otherwise return `_layoutError` without authoring fallback positions. Add viewport dimensions/safe-inset defaults to state.

- [ ] **Step 6: Replace radial expectations with ELK expectations and verify GREEN**

Update tests to assert one ELK call on a cold key, zero calls on an exact cache hit, `_layoutMode === "elk-scene"`, 32 routes in both fixture states, 24 contained expanded members, legacy input `x/y` values ignored, and a recoverable error on first-layout failure. Remove tests that require ELK not to run or require spiral/radial coordinates.

Run: `cd elixir/web-ng/assets && bunx vitest run js/lib/god_view/layout_elk_scene.test.js js/lib/god_view/layout_topology_state_methods.test.js`

Expected: all tests pass.

- [ ] **Step 7: Commit the ELK geometry authority**

```bash
git add elixir/web-ng/assets/js/lib/god_view/layout_elk_scene.js elixir/web-ng/assets/js/lib/god_view/layout_elk_scene.test.js elixir/web-ng/assets/js/lib/god_view/layout_topology_state_methods.js elixir/web-ng/assets/js/lib/god_view/layout_topology_state_methods.test.js elixir/web-ng/assets/js/lib/god_view/lifecycle_bootstrap_state_defaults_methods.js
git commit -m "feat(topology): make compound ELK scene authoritative"
```

### Task 3: Routed deck.gl Transport Rendering

**Files:**
- Modify: `elixir/web-ng/assets/js/lib/god_view/rendering_graph_data_methods.js`
- Modify: `elixir/web-ng/assets/js/lib/god_view/rendering_graph_data_methods.test.js`
- Modify: `elixir/web-ng/assets/js/lib/god_view/rendering_graph_layer_transport_methods.js`
- Modify: `elixir/web-ng/assets/js/lib/god_view/rendering_graph_layer_transport_methods.test.js`
- Modify: `elixir/web-ng/assets/js/lib/god_view/rendering_style_edge_particle_methods.js`
- Modify: `elixir/web-ng/assets/js/lib/god_view/rendering_style_edge_particle_methods.test.js`

**Interfaces:**
- Consumes: `graph._topologyScene.routes` from Task 2.
- Produces: edge datum `path: [[x, y, 0], ...]`, `relationIds`, and `midpoint` sampled at half cumulative path distance.
- Produces: `PathLayer` mantle/crust/selection layers with `getPath: edge => edge.path`.

- [ ] **Step 1: Write failing route-data tests**

```js
it("uses pre-laid scene routes without post-layout aggregation", async () => {
  const graph = expandedFarm01Graph()
  const input = prepareTopologySceneInput(graph)
  const scene = await layoutTopologyScene(input, {engine: new ELK(), profile: LANDSCAPE_PROFILE})
  const laidOut = applyTopologySceneToGraph(graph, scene)
  const out = ctx.buildVisibleGraphData({shape: "local", ...laidOut})
  expect(out.edgeData).toHaveLength(32)
  expect(out.edgeData.every((edge) => edge.path.length >= 2)).toBe(true)
  expect(out.edgeData.flatMap((edge) => edge.relationIds).sort()).toEqual(expectedRelationIds)
})
```

Also assert a route's midpoint follows cumulative polyline distance rather than averaging endpoints.

- [ ] **Step 2: Verify route-data RED**

Run: `cd elixir/web-ng/assets && bunx vitest run js/lib/god_view/rendering_graph_data_methods.test.js`

Expected: FAIL because current edge data rebuilds direct source/target positions and aggregates after layout.

- [ ] **Step 3: Consume scene routes in `buildVisibleGraphData`**

For local `_topologyScene` graphs, construct edge data directly from the 32 decoded route entities and their pre-aggregated metadata. Keep the existing regional/global clustered fallback isolated from the managed local topology scene. Do not call `collapseExpandedMemberTrunks` or `aggregateVisibleEdges` on scene routes.

- [ ] **Step 4: Write failing PathLayer tests**

Assert the transport layers are `PathLayer` instances, expose the exact route array through `getPath`, use the same path for hover/selection, do not construct an `ArcLayer` for routed topology edges, and omit particle layers for paths with more than two points.

Run: `cd elixir/web-ng/assets && bunx vitest run js/lib/god_view/rendering_graph_layer_transport_methods.test.js js/lib/god_view/rendering_style_edge_particle_methods.test.js`

Expected: FAIL because current transport uses `LineLayer`/`ArcLayer` and direct-chord particles.

- [ ] **Step 5: Implement routed layers and verify GREEN**

Replace mantle/crust topology strokes with `PathLayer`, preserve widths and interaction keys, select one deterministic route status color, and disable particles for bent routes.

Run: `cd elixir/web-ng/assets && bunx vitest run js/lib/god_view/rendering_graph_data_methods.test.js js/lib/god_view/rendering_graph_layer_transport_methods.test.js js/lib/god_view/rendering_style_edge_particle_methods.test.js`

Expected: all tests pass.

- [ ] **Step 6: Commit routed rendering**

```bash
git add elixir/web-ng/assets/js/lib/god_view/rendering_graph_data_methods.js elixir/web-ng/assets/js/lib/god_view/rendering_graph_data_methods.test.js elixir/web-ng/assets/js/lib/god_view/rendering_graph_layer_transport_methods.js elixir/web-ng/assets/js/lib/god_view/rendering_graph_layer_transport_methods.test.js elixir/web-ng/assets/js/lib/god_view/rendering_style_edge_particle_methods.js elixir/web-ng/assets/js/lib/god_view/rendering_style_edge_particle_methods.test.js
git commit -m "feat(topology): render ELK relation routes"
```

### Task 4: Screen-Space Label Admission

**Files:**
- Create: `elixir/web-ng/assets/js/lib/god_view/rendering_label_collision.js`
- Create: `elixir/web-ng/assets/js/lib/god_view/rendering_label_collision.test.js`
- Modify: `elixir/web-ng/assets/js/lib/god_view/rendering_graph_layer_node_methods.js`
- Modify: `elixir/web-ng/assets/js/lib/god_view/rendering_graph_layer_node_methods.test.js`

**Interfaces:**
- Produces: `admitTopologyLabels({candidates, glyphBoxes, routeCorridors, safeRect, measureText})` returning `{admitted, detailsFallbackIds}`, where each admitted record is `{nodeId, anchor, box, pixelOffset, textAnchor, alignmentBaseline}`.
- Consumes: projected node positions, visible route corridors, existing zoom-tier candidate budget, selected/focused state, and measured DOM safe rectangle.

- [ ] **Step 1: Write failing pure collision tests**

```js
it("admits deterministic labels without label, non-owner glyph, route, or chrome collisions", () => {
  const result = admitTopologyLabels(denseExpandedLabelCase())
  expect(pairwiseIntersections(result.map((item) => item.box))).toEqual([])
  expect(intersectionsWithObstacles(result)).toEqual([])
  expect(result.map((item) => item.nodeId)).toEqual(expectedPriorityOrder)
})

it("keeps selected identity in details when every canvas candidate is blocked", () => {
  const result = admitTopologyLabels(blockedSelectedLabelCase())
  expect(result.admitted.some((item) => item.nodeId === "selected")).toBe(false)
  expect(result.detailsFallbackIds).toEqual(["selected"])
})
```

- [ ] **Step 2: Verify label RED**

Run: `cd elixir/web-ng/assets && bunx vitest run js/lib/god_view/rendering_label_collision.test.js`

Expected: FAIL because the pure collision module does not exist.

- [ ] **Step 3: Implement minimal deterministic admission**

Use top/right/bottom/left candidates, `4` pixel padding, conservative text width fallback, and stable priority. Exclude the candidate's owning glyph from obstacles. Evict lower-priority admitted labels for selected/focused labels. Treat route stroke width plus padding as corridors. Return details fallbacks rather than accepting chrome collisions.

- [ ] **Step 4: Integrate admission after existing budgets**

Keep `labelBudgetForShape` and expanded-member budgets as the candidate ceiling. Project candidates through the active deck view state, run admission, and feed admitted offsets/anchors into `TextLayer`. Suppress overview edge labels. Recompute on view-state changes without touching `_topologyScene` or invoking ELK.

- [ ] **Step 5: Verify GREEN**

Run: `cd elixir/web-ng/assets && bunx vitest run js/lib/god_view/rendering_label_collision.test.js js/lib/god_view/rendering_graph_layer_node_methods.test.js`

Expected: all tests pass, including the 24-member fixture collision case.

- [ ] **Step 6: Commit label admission**

```bash
git add elixir/web-ng/assets/js/lib/god_view/rendering_label_collision.js elixir/web-ng/assets/js/lib/god_view/rendering_label_collision.test.js elixir/web-ng/assets/js/lib/god_view/rendering_graph_layer_node_methods.js elixir/web-ng/assets/js/lib/god_view/rendering_graph_layer_node_methods.test.js
git commit -m "feat(topology): declutter labels in screen space"
```

### Task 5: Safe Fit, Focus, and Resize Profiles

**Files:**
- Create: `elixir/web-ng/assets/js/lib/god_view/rendering_scene_view.js`
- Create: `elixir/web-ng/assets/js/lib/god_view/rendering_scene_view.test.js`
- Modify: `elixir/web-ng/assets/js/lib/god_view/rendering_graph_view_methods.js`
- Modify: `elixir/web-ng/assets/js/lib/god_view/rendering_graph_view_methods.test.js`
- Modify: `elixir/web-ng/assets/js/lib/god_view/lifecycle_dom_setup_methods.js`
- Modify: `elixir/web-ng/assets/js/lib/god_view/lifecycle_dom_setup_methods.test.js`
- Modify: `elixir/web-ng/assets/js/lib/god_view/lifecycle_bootstrap_runtime_methods.js`

**Interfaces:**
- Produces: `measureGodViewSafeRect(el)` from actual control/status DOM bounds.
- Produces: `fitTopologyScene({scene, viewport, safeRect, glyphBoxes, admitLabels})` returning `{viewState, admittedLabels}` after at most two passes.
- Produces: `focusTopologyGroup({scene, groupId, viewport, safeRect})`.
- Consumes: Task 2 scene bounds/groups/routes and Task 4 label admission.

- [ ] **Step 1: Write failing Fit and focus tests**

Assert full-scene visual AABBs remain inside the safe rectangle, projected glyph boxes do not overlap within `1` pixel, two identical Fit calls return the same view state/labels, focus includes group+anchor+trunk rather than the whole graph, and user-locked expansion leaves camera untouched.

```js
it("fits the expanded scene idempotently inside measured chrome", () => {
  const first = fitTopologyScene(expandedSceneCase())
  const second = fitTopologyScene({...expandedSceneCase(), previous: first})
  expect(second).toEqual(first)
  expect(visualBounds(first)).toBeInside(safeRect, 1)
  expect(glyphIntersections(first)).toEqual([])
})
```

- [ ] **Step 2: Verify camera RED**

Run: `cd elixir/web-ng/assets && bunx vitest run js/lib/god_view/rendering_scene_view.test.js js/lib/god_view/rendering_graph_view_methods.test.js`

Expected: FAIL because current Fit only uses node centers/radii and focus uses a conflicting Y-offset convention.

- [ ] **Step 3: Implement the pure two-pass solver and integrate view methods**

Fit scene world geometry with measured safe insets and conservative glyph allowance, admit labels, refit once only when retained labels escape the safe rectangle, then re-admit/cull. Focus only the selected compound group, anchor, and trunk. Use one offset-sign convention. Keep managed views in local zoom tier so the ELK scene is not immediately replaced by regional grid clustering.

- [ ] **Step 4: Add ResizeObserver profile tests**

Assert same-bucket resize refits without ELK invalidation, crossing the `1.2` usable-aspect threshold invalidates the layout key exactly once, and user-locked camera resizes Deck without automatic refit.

- [ ] **Step 5: Implement ResizeObserver behavior and verify GREEN**

Measure the topology container rather than only listening to window resize. Store the quantized profile in state, request a fresh snapshot layout only on profile change, and otherwise recompute view/labels.

Run: `cd elixir/web-ng/assets && bunx vitest run js/lib/god_view/rendering_scene_view.test.js js/lib/god_view/rendering_graph_view_methods.test.js js/lib/god_view/lifecycle_dom_setup_methods.test.js`

Expected: all tests pass.

- [ ] **Step 6: Commit managed camera behavior**

```bash
git add elixir/web-ng/assets/js/lib/god_view/rendering_scene_view.js elixir/web-ng/assets/js/lib/god_view/rendering_scene_view.test.js elixir/web-ng/assets/js/lib/god_view/rendering_graph_view_methods.js elixir/web-ng/assets/js/lib/god_view/rendering_graph_view_methods.test.js elixir/web-ng/assets/js/lib/god_view/lifecycle_dom_setup_methods.js elixir/web-ng/assets/js/lib/god_view/lifecycle_dom_setup_methods.test.js elixir/web-ng/assets/js/lib/god_view/lifecycle_bootstrap_runtime_methods.js
git commit -m "feat(topology): fit complete ELK scene safely"
```

### Task 6: Bazel Gates, Browser Acceptance, and Demo Verification

**Files:**
- Modify: `elixir/web-ng/assets/BUILD.bazel`
- Create: `elixir/web-ng/test/playwright/god_view_elk_scene.playwright.js`
- Create: `elixir/web-ng/test/playwright/BUILD.bazel`
- Modify: `elixir/web-ng/assets/js/lib/god_view/rendering_graph_core_methods.js`
- Create: `elixir/web-ng/assets/js/lib/god_view/rendering_graph_core_methods.test.js`
- Modify: `openspec/changes/refactor-god-view-elk-scene/tasks.md`

**Interfaces:**
- Produces: Bazel unit target `//elixir/web-ng/assets:god_view_scene_tests` with fixture modules declared inputs.
- Produces: Bazel acceptance target `//elixir/web-ng/test/playwright:god_view_elk_scene_acceptance` tagged `acceptance_test`.
- Produces: test-only `window.__SR_GOD_VIEW_GEOMETRY__()` hook exposing scene key, route/node/group/glyph/label boxes, safe rectangle, view state, and semantic/render counts only when acceptance mode is enabled.

- [ ] **Step 1: Write a failing geometry-hook contract test**

Assert production/default rendering does not expose the hook, acceptance mode returns immutable plain data, and the hook contains no telemetry payloads or credentials.

Run: `cd elixir/web-ng/assets && bunx vitest run js/lib/god_view/rendering_graph_core_methods.test.js`

Expected: FAIL because the acceptance-only hook does not exist.

- [ ] **Step 2: Implement the guarded hook and Bazel Vitest target**

Use a Bazel-owned JavaScript test runner invoking the checked-in Vitest dependency through `:node_modules`; declare God-View source/tests/fixtures as inputs and tag it as a normal unit test. The target must run from the assets package directory so ES module imports and elkjs resolution match local Bun behavior.

Run: `test -f .bazelrc.remote && bazel test -c opt --config=remote //elixir/web-ng/assets:god_view_scene_tests`

Expected: PASS and includes Task 1-5 suites.

- [ ] **Step 3: Add browser acceptance flow**

At a pinned `1920x1080` CSS viewport with DPR `1`, reduced motion, disabled animation, and `document.fonts.ready`, load the collapsed fixture, expand the declared 24-member cluster, invoke Fit twice, focus the group, add a second expansion, collapse/re-expand, and cross the viewport profile threshold. Read the geometry hook and assert fixture counts, zero non-nested AABB overlap, zero nonincident route interior intersection, zero admitted-label collision, safe bounds, Fit idempotence, and stable collapse/re-expand geometry. Capture screenshots and traces for collapsed, expanded, Fit, and concurrent-expanded states.

- [ ] **Step 4: Add the Bazel acceptance target and run it explicitly**

Declare the browser test and fixture inputs in a Bazel target tagged `acceptance_test`; use the repository's pinned browser/runtime mechanism and output screenshot/trace artifacts through declared test outputs.

Run: `test -f .bazelrc.remote && bazel test -c opt --config=remote //elixir/web-ng/test/playwright:god_view_elk_scene_acceptance --test_output=errors`

Expected: PASS with screenshots/traces retained by the test result.

- [ ] **Step 5: Run focused and repository verification**

Run, in order:

```bash
cd elixir/web-ng/assets && bunx vitest run js/lib/god_view/*.test.js
cd elixir/web-ng/assets && bun run lint:god_view
cd elixir/web-ng/assets && bun run typecheck:god_view
make test-toolchains
make test
openspec validate refactor-god-view-elk-scene --strict
openspec validate fix-topology-islands-and-cluster-expansion --strict
openspec validate refactor-topology-read-model-for-carrier-scale --strict
```

Expected: every command exits zero with no test warnings attributable to this change.

- [ ] **Step 6: Mark verified OpenSpec tasks and commit gates**

Mark only tasks demonstrated by the commands and browser artifacts as complete.

```bash
git add elixir/web-ng/assets/BUILD.bazel elixir/web-ng/test/playwright/BUILD.bazel elixir/web-ng/test/playwright/god_view_elk_scene.playwright.js elixir/web-ng/assets/js/lib/god_view/rendering_graph_core_methods.js elixir/web-ng/assets/js/lib/god_view/rendering_graph_core_methods.test.js openspec/changes/refactor-god-view-elk-scene openspec/changes/fix-topology-islands-and-cluster-expansion openspec/changes/refactor-topology-read-model-for-carrier-scale docs/superpowers/plans/2026-08-23-god-view-elk-scene.md
git commit -m "test(topology): gate ELK scene geometry"
```

- [ ] **Step 7: Roll and visually verify demo**

Use the repository `demo-web-ng-fastpath` skill to build and sign the web-ng-only image from the final commit. Wait for ArgoCD `Synced|Healthy|Succeeded`, then use the Playwright browser workflow against the demo farm01 topology page. Verify collapsed and expanded geometry invariants through the hook, inspect screenshots, and record the deployed immutable image tag and observed counts in the task report. Do not merge or push without the user's separate authorization.
