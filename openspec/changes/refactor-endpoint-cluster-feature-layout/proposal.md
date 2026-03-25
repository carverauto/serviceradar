# Change: Refactor endpoint cluster feature layout in God-View

## Why
`add-topology-endpoint-visibility` made discovered endpoints visible in God-View, but the expanded-cluster behavior is still not usable. When operators expand an endpoint group, member nodes and attachment edges are currently placed with generic radial math that flattens the cluster into a single visual plane, obscures nearby backbone links, and makes the topology read like a hairball instead of a structured network.

The deeper issue is architectural. The current implementation still treats an expanded endpoint cluster as a collection of points to "place nicely" after the graph is laid out. That leaves four concrete failure modes:
- the backbone and the endpoint feature are not treated as separate layout problems
- the expanded cluster is placed as individual points instead of as a reserved feature envelope
- the final point-collision cleanup can distort the feature back into a flat or messy bundle
- expand/collapse state and undo semantics are weak enough that reset/collapse can appear broken to operators

We need an explicit contract that endpoint cluster geometry is authored on the backend as a topology feature, not improvised in the renderer. The design direction should follow the practical ideas from feature-based topology layout work such as Archambault et al. ("TopoLayout: Graph Layout by Topological Features"): reserve area for meaningful subgraphs, lay those features out with feature-specific geometry, and reduce local crossings without disturbing the backbone layout.

The repository now includes a local checkout of `TopoMap-pp`, which gives us concrete source code for several geometry operations we can mirror instead of treating the paper as a purely conceptual reference. We should explicitly port or adapt the useful primitives from that code where they fit the endpoint-cluster problem.

## What Changes
- Add a `build-web-ui` requirement that endpoint clusters are laid out on the backend as area-bearing topology features rather than generic radial point sets.
- Make the backbone-layout contract explicit: endpoint attachment edges SHALL NOT participate in the primary backbone layout input, and cluster projection SHALL happen after the structural topology is laid out.
- Require collapsed endpoint groups to remain compact summaries that do not pull backbone structure into vertical or high-fanout distortion.
- Require expanded endpoint groups to use a deterministic anchored fan/sector layout with an explicit reserved footprint and envelope-aware placement, not just per-node radial spacing.
- Require a local orientation/crossing-reduction step so expanded cluster geometry chooses a sector that minimizes interference with adjacent topology.
- Require the post-projection cleanup step to preserve cluster feature geometry instead of allowing point-level collision cleanup to collapse a feature back into a flat bundle.
- Mirror portable `TopoMap-pp` geometry primitives where applicable, especially component-boundary selection, rotate/translate alignment, and bounded footprint scaling, while avoiding a fake "full TopoMap port" claim where the problem domains do not match.
- Require expansion state to participate in backend snapshot identity so expand/collapse/reset updates are never dropped as stale revisions.
- Require explicit and reversible cluster interaction semantics, including a reliable collapse/reset path that returns the view to the collapsed topology state.
- Add regression coverage for collapsed and expanded endpoint clusters, including spacing, angular spread, backbone preservation, deterministic orientation, and reversible expansion state.
- Keep the frontend render-only for endpoint-cluster geometry; coordinate authority remains in the backend snapshot pipeline and the frontend only sends user intent.

## Impact
- Affected specs:
  - `build-web-ui`
- Affected code:
  - `elixir/web-ng/lib/serviceradar_web_ng/topology/god_view_stream.ex`
  - `elixir/web-ng/lib/serviceradar_web_ng_web/channels/topology_channel.ex`
  - `elixir/web-ng/test/app_domain/topology/god_view_stream_test.exs`
  - `elixir/web-ng/assets/js/lib/god_view/lifecycle_stream_snapshot_methods.js`
  - `elixir/web-ng/assets/js/lib/god_view/lifecycle_bootstrap_channel_event_methods.js`
  - `elixir/web-ng/assets/js/lib/god_view/lifecycle_bootstrap_event_reset_view_methods.js`
  - `elixir/web-ng/assets/js/lib/god_view/rendering_selection_methods.js`
  - `elixir/web-ng/assets/js/lib/god_view/rendering_tooltip_methods.js`
  - `elixir/web-ng/lib/serviceradar_web_ng_web/live/topology_live/god_view.ex`
  - `elixir/web-ng/assets/js/lib/god_view/*` regression tests and snapshot fixtures
  - potentially `elixir/web-ng/native/god_view_nif/src/core/layout.rs` if footprint reservation or layout scoring is pushed into the native path
- Related active changes:
  - `add-topology-endpoint-visibility`
  - `refactor-topology-layout-stability-and-performance`
- Related source references:
  - `TopoMap-pp/topomap/TopoMap.py`
  - `TopoMap-pp/topomap/HierarchicalTopoMap.py`
  - `TopoMap-pp/topomap/utils.py`
  - `TopoMap-pp/topomap/UnionFindComponents.py`
