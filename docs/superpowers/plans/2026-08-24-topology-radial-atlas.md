# Topology Radial Atlas Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task.

**Goal:** Replace the unbounded one-scene topology canvas with a deterministic ELK Radial overview and bounded ELK Layered detail levels that remain legible, fit-able, and operable on real ServiceRadar data.

**Architecture:** A pure overview projection reduces the current snapshot to infrastructure anchors, collapsed endpoint census summaries, a deterministic minimum-trust spanning forest, and metadata-only cross-links. ELK Radial owns overview geometry; the existing strict ELK Layered scene owns bounded detail geometry. Exactly one layout mode owns a rendered scene at a time. Camera, label, and expansion lifecycle contracts operate on the accepted semantic level rather than trying to display every raw element globally.

**Tech Stack:** JavaScript ES modules, Vitest, ELK.js, Deck.gl, Phoenix LiveView, Bazel, Playwright CLI.

**Spec:** `openspec/changes/refactor-topology-read-model-for-carrier-scale/`

## Global Constraints

- The overview is deterministic for equivalent input regardless of raw node or edge order.
- Overview glyphs are limited to infrastructure nodes and one collapsed census summary per endpoint cluster. Plain endpoint members never enter overview ELK input.
- The overview ELK input is a forest (or a forest joined only by a zero-size synthetic super-root). Cyclic/rejected relations remain inspectable cross-link metadata and are never drawn as global overview routes.
- ELK Radial owns overview geometry. The existing strict ELK Layered adapter owns bounded detail geometry. No second browser layout or force simulation may mutate either scene.
- Every rendered semantic glyph has a persistent on-canvas identity label. If the current semantic level cannot label its glyphs, the graph must be coarsened or paged instead of rendering anonymous circles.
- Fit succeeds and contains every accepted nonempty scene in both landscape and portrait viewports. Fit is idempotent and the camera minimum zoom cannot exceed the computed fit zoom.
- Accepting an expanded graph is independent of camera focus. A focus miss or exception is nonfatal, preserves the accepted graph and revision, clears matching pending focus state, and emits diagnostics.
- Expansion is bounded: overview-to-detail replaces the active semantic level; it does not append arbitrary expanded groups to the overview.
- Layout/render/decode errors expose the phase, layout mode, graph key, revision, and actionable error text in browser diagnostics and the existing LiveView event path.
- Do not add shell scripts. Focused and repository-wide verification run through existing Bazel/Make targets.
- Use strict TDD: each behavior test is added and observed failing before production code is added.

---

## Task 1: Deterministic overview projection

**Files:**

- Create: `elixir/web-ng/assets/js/lib/god_view/topology_overview_projection.js`
- Create: `elixir/web-ng/assets/js/lib/god_view/topology_overview_projection.test.js`
- Read/reference: `elixir/web-ng/assets/js/lib/god_view/topology_scene_graph.js`
- Read/reference: `elixir/web-ng/assets/js/lib/god_view/topology_relation_identity.js`
- Fixture: `elixir/web-ng/assets/js/lib/god_view/fixtures/farm01_topology_regression.js`

### Step 1: Add failing behavior tests

- [ ] Add literal-fixture tests for `prepareTopologyOverviewInput(graph)` proving shuffled nodes/edges produce the same `graphKey`, `nodes`, `treeRelations`, `crossLinks`, and root order.
- [ ] Assert the canonical farm01 fixture produces exactly 12 overview glyphs (6 infrastructure plus 6 collapsed summaries), 11 tree routes (5 infrastructure forest relations plus 6 census leaves), 3 cross-links, 18 omitted attachment-only nodes, and one connected overview component.
- [ ] Add a cyclic three-node literal fixture and assert exactly two deterministic tree relations plus one cross-link.
- [ ] Add a disconnected literal fixture and assert a zero-size synthetic `overview:super-root` plus stable synthetic component relations, without exposing the synthetic node in the semantic manifest.
- [ ] Add malformed/self-loop/duplicate-edge cases and assert deterministic omission or aggregation rather than crashes.
- [ ] Run the focused test and confirm it fails because the module is absent:

```bash
bazel test -c opt --config=remote //elixir/web-ng/assets:god_view_scene_tests --test_filter=topology_overview_projection
```

### Step 2: Implement the pure projection

- [ ] Export this stable interface:

```js
export function prepareTopologyOverviewInput(graph) {
  return {
    nodes,
    roots,
    treeRelations,
    crossLinks,
    synthetic,
    graphKey,
    manifest,
  }
}
```

- [ ] Normalize node IDs and canonical undirected relation pairs. Aggregate all raw semantic relation IDs and evidence on the pair before ranking it.
- [ ] Treat endpoint anchors, explicitly backbone-plane nodes, and nodes incident to non-attachment relations as infrastructure. Add collapsed endpoint summaries as leaves after the infrastructure forest is chosen. Omit ordinary attachment-only nodes.
- [ ] Rank candidate infrastructure pairs by the literal trust tuple: direct physical/backbone `0`, logical `1`, hosted `2`, connectivity-forest bridge `3`, inferred `4`, observed `5`, unknown `6`, then canonical pair ID.
- [ ] Use deterministic Kruskal union-find. Accepted candidates are `treeRelations`; rejected candidates are `crossLinks` with all underlying semantic relation IDs and evidence metadata retained.
- [ ] Select each component root by `(role rank, descending original transport degree, infrastructure type rank, node ID)` and orient accepted relations using deterministic breadth-first traversal.
- [ ] Join multiple components only for ELK input using `overview:super-root` and stable synthetic relation IDs. Record synthetic IDs separately so adapters can strip them.
- [ ] Build `graphKey` from a stable serialization of semantic nodes, oriented tree relations, cross-links, roots, and synthetic IDs.

### Step 3: Verify and commit

- [ ] Re-run the focused test and the whole God View JS target.
- [ ] Mutation-check the ranking, edge rejection, summary-leaf addition, and shuffled-input tests.
- [ ] Commit only Task 1 files.

---

## Task 2: ELK Radial overview adapter

**Files:**

- Create: `elixir/web-ng/assets/js/lib/god_view/layout_elk_radial_overview.js`
- Create: `elixir/web-ng/assets/js/lib/god_view/layout_elk_radial_overview.test.js`
- Modify only if shared validation is required: `elixir/web-ng/assets/js/lib/god_view/acceptance_geometry_assertions.js`
- Read/reference: `elixir/web-ng/assets/js/lib/god_view/layout_elk_scene.js`

### Step 1: Add failing adapter tests

- [ ] Test `buildElkRadialOverviewGraph(input)` with literal input and assert it contains only the projected tree plus synthetic component joins, stable node ordering, and these ELK options:

```js
{
  "elk.algorithm": "radial",
  "org.eclipse.elk.radial.centerOnRoot": "true",
  "org.eclipse.elk.radial.sorter": "ID",
}
```

- [ ] Assert every semantic node gets a stable numeric `org.eclipse.elk.radial.orderId`, every root is explicitly represented, and no cross-link becomes an ELK edge.
- [ ] Test `decodeElkRadialOverview(layout, input)` using hand-written ELK output. Assert synthetic nodes/edges are stripped, semantic coordinates and routes are finite, relation IDs survive, bounds contain glyph envelopes and routes, and the scene exposes `crossLinks` plus the manifest.
- [ ] Test failures for missing node coordinates, unknown edge IDs, duplicate semantic geometry, nonfinite points, and missing expected tree relations.
- [ ] Run and observe red before implementation:

```bash
bazel test -c opt --config=remote //elixir/web-ng/assets:god_view_scene_tests --test_filter=layout_elk_radial_overview
```

### Step 2: Implement the adapter

- [ ] Export:

```js
export function buildElkRadialOverviewGraph(input) {}
export function decodeElkRadialOverview(layout, input) {}
export function validateTopologyOverview(scene, input) {}
export async function layoutTopologyOverview(input, elk) {}
export function applyTopologyOverviewToGraph(graph, scene) {}
```

- [ ] Give ELK only tree nodes/relations, deterministic child order, explicit root ordering, fixed node envelopes, stable padding/spacing, and no compaction option.
- [ ] Decode ELK sections into the renderer's immutable scene shape: semantic `nodes`, empty `groups`, semantic `routes`, `physicalRoutes`, empty `manifolds`, `crossLinks`, `bounds`, `graphKey`, `profileKey: "radial-overview"`, and `manifest`.
- [ ] Preserve original graph node indices and relation identity when applying geometry. Annotate `_layoutMode: "elk-radial-overview"`; never mutate the source graph.
- [ ] Validate exactly one finite geometry record per expected semantic glyph and tree route; reject synthetic leakage and cross-link routes.

### Step 3: Verify and commit

- [ ] Re-run focused adapter and projection tests plus the whole God View JS target.
- [ ] Commit only Task 2 files.

---

## Task 3: Mutually exclusive overview/detail layout modes and cache

**Files:**

- Create: `elixir/web-ng/assets/js/lib/god_view/topology_layout_mode.js`
- Create: `elixir/web-ng/assets/js/lib/god_view/topology_layout_mode.test.js`
- Modify: `elixir/web-ng/assets/js/lib/god_view/layout_topology_state_methods.js`
- Modify: `elixir/web-ng/assets/js/lib/god_view/layout_topology_state_methods.test.js`
- Modify: `elixir/web-ng/assets/js/lib/god_view/rendering_graph_data_methods.js`
- Modify: `elixir/web-ng/assets/js/lib/god_view/rendering_graph_data_methods.test.js`
- Modify as required for accepted mode strings: `elixir/web-ng/assets/js/lib/god_view/GodViewLayoutEngine_api_contract.test.js`

### Step 1: Add failing mode and state tests

- [ ] Define tests for:

```js
export function hasManagedTopologyScene(graph) {}
export function isOverviewScene(graph) {}
export function isDetailScene(graph) {}
export function topologySemanticLevel(graph) {}
```

- [ ] Assert collapsed snapshots choose `elk-radial-overview`, while a graph explicitly marked as bounded cluster detail chooses the existing `elk-scene-detail` Layered adapter.
- [ ] Assert cache keys include semantic level and adapter profile, so radial geometry can never hydrate a layered scene or vice versa.
- [ ] Assert a cached overview rebuilds live node/relation metadata while reusing geometry, including current cross-link metadata.
- [ ] Assert rendering recognizes both managed modes and rejects legacy/error modes as route authorities.
- [ ] Run focused tests and observe the new expectations fail.

### Step 2: Wire layout selection and cache hydration

- [ ] Use `prepareTopologyOverviewInput` plus `layoutTopologyOverview` for overview snapshots and preserve `prepareTopologySceneInput` plus `layoutTopologyScene` for bounded detail.
- [ ] Replace exact `"elk-scene"` checks with the named mode predicates; keep one `_topologyScene` authority per graph.
- [ ] Name the Layered bounded mode `elk-scene-detail` throughout state, renderer predicates, summary text, and error modes.
- [ ] Include semantic level, adapter profile, graph key, and viewport-dependent inputs only where the adapter actually consumes them in cache keys.
- [ ] Preserve last-known-good geometry only when mode, graph key, and semantic level match.

### Step 3: Verify and commit

- [ ] Re-run all affected focused tests and `//elixir/web-ng/assets:god_view_scene_tests`.
- [ ] Commit only Task 3 files.

---

## Task 4: Complete labels and a containment-first Fit contract

**Files:**

- Modify: `elixir/web-ng/assets/js/lib/god_view/rendering_graph_layer_node_methods.js`
- Modify: `elixir/web-ng/assets/js/lib/god_view/rendering_graph_layer_node_methods.test.js`
- Modify: `elixir/web-ng/assets/js/lib/god_view/rendering_label_collision.js`
- Modify: `elixir/web-ng/assets/js/lib/god_view/rendering_label_collision.test.js`
- Modify: `elixir/web-ng/assets/js/lib/god_view/rendering_scene_view.js`
- Modify: `elixir/web-ng/assets/js/lib/god_view/rendering_scene_view.test.js`
- Modify: `elixir/web-ng/assets/js/lib/god_view/rendering_graph_view_methods.js`
- Modify: `elixir/web-ng/assets/js/lib/god_view/rendering_graph_view_methods.test.js`
- Modify: `elixir/web-ng/assets/god_view_acceptance_geometry_observer.js`
- Modify: `elixir/web-ng/assets/god_view_acceptance_geometry_observer.test.js`

### Step 1: Add failing label and Fit tests

- [ ] Replace anonymous-glyph quota expectations with literal overview and detail fixtures asserting `labelIds` equals `glyphIds` for every accepted semantic glyph.
- [ ] Make collision admission return deterministic `missingRequiredLabelIds`; assert a semantic scene with missing required labels is rejected/coarsened rather than silently rendered.
- [ ] Add landscape and portrait Fit tests asserting every node envelope, route point, and label-safe envelope is inside the usable viewport after Fit.
- [ ] Assert two consecutive Fit calls yield the same center/zoom within numeric tolerance and both return success.
- [ ] Assert `minZoom <= fitZoom` for a deliberately wide/tall scene that previously tripped the fixed-pixel minimum-scale floor.
- [ ] Update the geometry observer contract to expose `semanticLevel`, `glyphIds`, `labelIds`, and `unlabeledGlyphIds`; add a failing test requiring the last array to be empty.

### Step 2: Implement semantic label completeness

- [ ] Remove global/local label quotas as an admission mechanism for managed topology scenes. All visible semantic nodes are required label candidates.
- [ ] Keep deterministic collision placement, but surface any missing required IDs. The caller must reject/coarsen the semantic level; it may not render the corresponding anonymous glyph.
- [ ] Preserve selected/hovered label priority only for placement choice, not label existence.

### Step 3: Implement containment-first Fit

- [ ] Compute fit from accepted scene bounds plus measured safe insets and label/glyph padding. Clamp only against a permissive absolute camera floor, never a fixed-pixel separation scale that exceeds containment.
- [ ] Set effective `minZoom` no greater than the computed fit zoom. Return a structured success result and make repeated calls idempotent.
- [ ] Keep fixed-pixel glyph separation as a semantic-level admission/coarsening concern, not a reason to forbid fitting an already accepted scene.

### Step 4: Verify and commit

- [ ] Re-run all label, scene-view, graph-view, observer, and full God View JS tests.
- [ ] Commit only Task 4 files.

---

## Task 5: Bounded expansion lifecycle and actionable diagnostics

**Files:**

- Modify: `elixir/web-ng/assets/js/lib/god_view/lifecycle_stream_snapshot_methods.js`
- Modify: `elixir/web-ng/assets/js/lib/god_view/lifecycle_stream_snapshot_methods.test.js`
- Modify as required: `elixir/web-ng/assets/js/lib/god_view/lifecycle_bootstrap_channel_event_methods.js`
- Modify corresponding test: `elixir/web-ng/assets/js/lib/god_view/lifecycle_bootstrap_channel_event_methods.test.js`
- Modify: `elixir/web-ng/assets/js/lib/god_view/lifecycle_bootstrap_state_defaults_methods.js`
- Modify corresponding test: `elixir/web-ng/assets/js/lib/god_view/lifecycle_bootstrap_state_defaults_methods.test.js`

### Step 1: Add failing lifecycle tests

- [ ] Test that graph acceptance/render completes and advances revision before any focus attempt.
- [ ] Test `focusClusterNeighborhood` returning false and throwing: both preserve the expanded detail graph, advance the revision, clear matching `pendingClusterFocus`, and emit a diagnostic without setting topology unavailable.
- [ ] Test expand cluster A, return to overview, then expand cluster B; assert no stale focus or cache key blocks the second transition.
- [ ] Assert an overview expansion request declares/replaces the bounded semantic level instead of accumulating globally expanded clusters.
- [ ] Assert layout/render/decode error payloads include `phase`, `layout_mode`, `graph_key`, and `revision` alongside the actionable message.

### Step 2: Separate acceptance from camera focus

- [ ] Commit layout state, graph, render, revision, and topology stamp in the acceptance transaction.
- [ ] Run focus afterward in its own guarded block. Clear the matching pending focus in `finally`; emit `focus_error` diagnostics for false/throw without restoring the previous graph.
- [ ] Represent active semantic level and bounded focus target explicitly in lifecycle state. Clear it on return/reset to overview.
- [ ] Keep genuine render failures rollback-safe, but never classify camera focus failure as a render failure.

### Step 3: Verify and commit

- [ ] Re-run lifecycle focused tests and the full God View JS target.
- [ ] Commit only Task 5 files.

---

## Task 6: Browser acceptance on the real CNPG topology

**Files:**

- Modify: `elixir/web-ng/assets/god_view_elk_scene_acceptance.playwright.js`
- Modify as required: `elixir/web-ng/assets/god_view_elk_scene_harness.js`
- Modify: `elixir/web-ng/assets/js/lib/god_view/README.md`
- Modify OpenSpec task checkboxes only after evidence exists: `openspec/changes/refactor-topology-read-model-for-carrier-scale/tasks.md`

### Step 1: Update deterministic browser acceptance

- [ ] Replace acceptance of sparse labels/unbounded multi-cluster expansion with these contracts:
  - overview uses `elk-radial-overview` and has zero unlabeled glyph IDs;
  - cross-links are counted/disclosed but absent from overview route geometry;
  - Fit succeeds twice and contains all geometry at landscape and portrait sizes;
  - one cluster enters `elk-scene-detail`, return restores overview, and a second cluster can enter detail;
  - focus failure does not surface topology unavailable;
  - no route intersects a non-endpoint glyph and no semantic route overlaps another semantic route.
- [ ] Run deterministic browser acceptance through the existing Bazel target(s) documented by the current harness.

### Step 2: Start local web-ng against demo CNPG

- [ ] From the isolated worktree, run the repository helper in check mode, then start mode:

```bash
.agents/skills/demo-cnpg-local-web-ng/scripts/start-local-web-ng.sh --check
.agents/skills/demo-cnpg-local-web-ng/scripts/start-local-web-ng.sh
```

- [ ] Confirm `mix phx.server` listens locally, the dashboard authenticates with the skill-provided credentials, and the live topology stream reaches the browser.
- [ ] Capture browser console/page errors and the God View geometry observer before interacting.

### Step 3: Exercise the live UI with Playwright CLI

- [ ] Use a named `playwright-cli` session. Capture screenshots for:
  - initial radial overview after Fit;
  - endpoint cluster A detail;
  - returned overview;
  - endpoint cluster B detail;
  - portrait-width overview after Fit.
- [ ] For every state, evaluate the observer and require: correct semantic level, zero unlabeled glyphs, all scene bounds inside the viewport, finite routes, and no topology-unavailable status.
- [ ] Save screenshots under `.playwright-cli/` or `/tmp`; never commit authentication/session data.
- [ ] If demo data does not exercise the farm01 cluster shapes, repeat the same local server/browser procedure against farm01 before acceptance is considered complete.

### Step 4: Repository verification and commit

- [ ] Run:

```bash
openspec validate refactor-topology-read-model-for-carrier-scale --strict
bazel test -c opt --config=remote //elixir/web-ng/assets:god_view_scene_tests
make lint
make test
```

- [ ] Read every command result and retain explicit failure branches; do not infer success from a process merely finishing.
- [ ] Update only completed OpenSpec task checkboxes and document the two semantic levels plus scale limits in the God View README.
- [ ] Commit Task 6 files and final verification documentation.

---

## Final review and delivery

- [ ] Run a whole-branch code review against the merge base with the plan and OpenSpec as authority.
- [ ] Resolve all Critical/Important findings and re-run their covering tests.
- [ ] Use `superpowers:verification-before-completion`; re-run any evidence that is stale after review fixes.
- [ ] Rebase the feature branch on current `github/staging`, resolve conflicts without weakening the contracts, and repeat focused plus repository verification.
- [ ] Push with an explicit refspec only:

```bash
git push github codex/topology-radial-atlas:refs/heads/codex/topology-radial-atlas
```

- [ ] Open a GitHub PR against `staging` using `gh`; include live screenshots, observer evidence, exact test commands, and the scale boundary (browser layouts consume bounded levels, never 50k–1M raw elements at once).
