# Change: Refactor God-View radial hub-and-spoke layout

## Why
The current God-View topology renderer is failing at the basic operator job of making backbone connectivity obvious. The default graph is trying to solve too many different geometry problems at once: infrastructure transport, endpoint attachment summaries, expanded endpoint members, unresolved/unplaced devices, and mixed evidence classes all influence the same visible layout pass.

In the current implementation this produces three concrete layout pathologies:
- The intended "organic radial" layout is not the dominant path in practice. `requiresFullElkLayout/1` escalates to a full ELK solve as soon as endpoint-summary/member nodes or endpoint-attachment edges are present, which is true for many real graphs.
- The so-called radial layout is actually a spanning-tree plus force-relaxation heuristic (`buildBackboneTree`, `assignOrganicBackbonePositions`, `relaxBackboneComponent`) rather than a true hub-and-spoke contract, so cycles and cross-links destabilize the output.
- Geometry is still being distorted after placement (`normalizeHorizontalLayout`) and the codebase still contains dead/legacy placement helpers (`applyEndpointProjectionLayout`, backend-authored cluster coordinates), which obscures which algorithm is actually responsible for operator-visible results.

The result is a graph that looks arbitrary instead of intentional. We need a simpler contract: choose a deterministic hub, place infrastructure in bounded radial tiers around it, and treat endpoint fanout as attached spoke decorations rather than peers in the backbone solve.

## What Changes
- Define the default God-View layout contract as a deterministic radial hub-and-spoke topology for infrastructure transport.
- Restrict the primary backbone solve to promotable transport relations only; endpoint-attachment, unresolved, and diagnostic-only relations SHALL NOT influence backbone coordinates.
- Replace the current tree-plus-force-relaxation and endpoint-heavy full-ELK fallback with one explicit default layout path:
  - select a deterministic hub/root from bounded infrastructure nodes
  - place backbone tiers in radial depth bands around that hub
  - place endpoint summaries and expanded endpoint members as anchored spoke decorations around their owning infrastructure node
- Remove post-layout geometry distortion and retire dead/legacy competing placement helpers from the default path.
- Add regression fixtures and acceptance tests for small and medium hub-and-spoke topologies so operator-visible layout quality is objective.

## Impact
- Affected specs:
  - `build-web-ui`
- Affected code:
  - `elixir/web-ng/assets/js/lib/god_view/layout_topology_state_methods.js`
  - `elixir/web-ng/assets/js/lib/god_view/lifecycle_stream_snapshot_methods.js`
  - `elixir/web-ng/assets/js/lib/god_view/rendering_graph_data_methods.js`
  - `elixir/web-ng/assets/js/lib/god_view/rendering_graph_view_methods.js`
  - `elixir/web-ng/lib/serviceradar_web_ng/topology/god_view_stream.ex`
  - God-View frontend layout regression tests

## Relationship to Existing Changes
- Builds on `refactor-topology-read-model-for-carrier-scale`, but is narrower and more explicit about the operator-facing default geometry contract.
- Replaces the remaining practical ambiguity left by `refactor-topology-layout-stability-and-performance`; this change is about the visible default topology shape, not just layout determinism/performance in the abstract.
