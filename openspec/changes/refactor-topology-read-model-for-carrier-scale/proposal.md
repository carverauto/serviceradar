# Change: Refactor topology read model for carrier scale

## Why
The current God-View pipeline mixes transport topology, endpoint attachments, unresolved topology sightings, and heuristic causal coloring into one graph surface. In practice this produces unreadable layouts on small networks, blank first loads when the stream bootstrap races, and a rendering contract that cannot scale to large environments because every raw relation is treated as something the canvas might try to lay out.

We need a carrier-scale topology contract that makes the default view bounded, trustworthy, and operationally useful. The system should show backbone connectivity first, summarize endpoint fanout instead of drawing every leaf, quarantine unresolved identities until they are promotable, and only claim causal impact when there is actual evidence.

## What Changes
- Add a carrier-scale topology read model that separates the default transport backbone from endpoint census and endpoint drill-down neighborhoods.
- Require the default God-View snapshot to be bounded and infrastructure-centric regardless of how many endpoint attachments exist in the source data.
- Prevent unresolved topology sightings, null-neighbor rows, and duplicate identity fragments from rendering as first-class infrastructure peers in the default graph.
- Make topology geometry single-authority in the frontend: the backend authors bounded topology semantics and expansion metadata, and the frontend performs the only layout pass for backbone and bounded endpoint neighborhoods.
- Add a reliable bootstrap path that fetches the latest snapshot over HTTP before joining streaming updates, with stream failure fallback.
- Narrow the health/causal overlay so `Affected` is reserved for evidence-backed impact paths instead of a generic three-hop propagation from unhealthy nodes.
- Add label-density budgets, visible-node budgets, and quality telemetry so the topology surface degrades gracefully and fails loudly when source data quality regresses.

## Impact
- Affected specs:
  - `build-web-ui`
  - `network-discovery`
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
- Builds on the operator goals behind `add-topology-endpoint-visibility`, `add-topology-default-clustered-view`, and `refactor-topology-layout-stability-and-performance`, but intentionally replaces their current architectural assumptions where they still allow mixed graph semantics, split layout authority, or unbounded endpoint expansion.
