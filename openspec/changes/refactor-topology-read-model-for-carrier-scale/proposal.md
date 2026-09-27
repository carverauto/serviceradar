# Change: Refactor topology read model for carrier scale

## Why
The current God-View pipeline mixes transport topology, endpoint attachments, unresolved topology sightings, and heuristic causal coloring into one graph surface. In practice this produces unreadable layouts on small networks, blank first loads when the stream bootstrap races, and a rendering contract that cannot scale to large environments because every raw relation is treated as something the canvas might try to lay out.

We need a carrier-scale topology contract that makes the default view bounded, trustworthy, and operationally useful. The system should show backbone connectivity first, summarize endpoint fanout instead of drawing every leaf, quarantine unresolved identities until they are promotable, and only claim causal impact when there is actual evidence.

## What Changes
- Add a carrier-scale topology read model that separates the default transport backbone from endpoint census and endpoint drill-down neighborhoods.
- Require the default God-View snapshot to be bounded and infrastructure-centric regardless of how many endpoint attachments exist in the source data.
- Prevent unresolved topology sightings, null-neighbor rows, and duplicate identity fragments from rendering as first-class infrastructure peers in the default graph.
- Make topology geometry single-authority in the frontend: the backend authors bounded topology semantics and expansion metadata, and the frontend performs the only layout pass for backbone and bounded endpoint neighborhoods.
- Replace the one-size-fits-all layered scene with a multi-resolution topology atlas: a deterministic transport forest drives the radial overview, non-tree cross-links are summarized until focused, and bounded detail scenes may select a different ELK strategy without mixing coordinate authorities inside one scene.
- Deliver semantic atlas levels (global, site or transport component, infrastructure neighborhood, and paged endpoint membership) as bounded schema-3 Arrow batches over HTTP. Keep stable level and parent identifiers, revision-aware caches, and server-enforced node, relation, label, member, and byte budgets.
- Bootstrap the global level over HTTP and use the topology channel only for bounded revision invalidations and small changes. Prefetch the child of the hovered aggregate and reuse compatible parent scenes on return.
- Narrow the health/causal overlay so `Affected` is reserved for evidence-backed impact paths instead of a generic three-hop propagation from unhealthy nodes.
- Add label-density budgets, visible-node budgets, and quality telemetry so the topology surface degrades gracefully and fails loudly when source data quality regresses.

## Impact
- Affected specs:
  - `build-web-ui`
  - `network-discovery`
  - `topology-god-view`
- Affected code:
  - `elixir/web-ng/lib/serviceradar_web_ng/topology/runtime_graph.ex`
  - `elixir/web-ng/lib/serviceradar_web_ng/topology/god_view_stream.ex`
  - `elixir/web-ng/lib/serviceradar_web_ng_web/channels/topology_channel.ex`
  - `elixir/web-ng/lib/serviceradar_web_ng_web/controllers/topology_snapshot_controller.ex`
  - `elixir/web-ng/lib/serviceradar_web_ng_web/live/topology_live/god_view.ex`
  - `elixir/web-ng/assets/js/lib/god_view/*`
  - `elixir/serviceradar_core/lib/serviceradar/network_discovery/topology_graph.ex`
  - topology snapshot/runtime graph/frontend regression tests

## Dependencies
- [Issue #4774](https://github.com/carverauto/serviceradar/issues/4774) delivers the semantic-level contract in this change. Evidence-backed `Affected` behavior and quarantine diagnostics remain separate work in this carrier-scale change.
- [Issue #4749](https://github.com/carverauto/serviceradar/issues/4749) supplies schema 3, columnar decoding, WebGPU-only rendering, and procedural per-edge packet flow. Implement the server read model and level-fetch contract first; integrate the client cache and navigation after that dependency lands. Do not create another payload format or a competing renderer.
- Builds on the operator goals behind `add-topology-endpoint-visibility`, `add-topology-default-clustered-view`, and `refactor-topology-layout-stability-and-performance`, but intentionally replaces their current architectural assumptions where they still allow mixed graph semantics, split layout authority, or unbounded endpoint expansion.
- Reuses the renderer-neutral scene, route rendering, collision admission, camera measurement, and dense fixtures delivered by `refactor-god-view-elk-scene`, but supersedes that change's assumption that every bounded semantic relation must participate in one layered compound layout. The carrier-scale atlas owns deterministic forest projection, level-specific layout selection, cross-link disclosure, visible-member and paging budgets, semantic labels, HTTP bootstrap, and causal semantics. Each accepted scene still has exactly one frontend geometry authority.
