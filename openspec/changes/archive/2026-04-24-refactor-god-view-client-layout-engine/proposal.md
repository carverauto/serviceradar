# Change: Refactor God-View to a client-side layout engine

## Why
The current God-View topology layout path is not converging. Endpoint-cluster expansion still produces overlapping or duplicated-looking groups, reset/collapse behavior is difficult to reason about, and backend-authored geometry changes have not produced a stable or readable topology for real endpoint-heavy graphs.

The deeper issue is architectural. We are asking the backend snapshot builder to solve both topology semantics and final graph drawing. That has forced `god_view_stream.ex` to accumulate custom geometry, collision, caching, and state-revision logic that mature graph layout engines already solve better on the client. We should move visible coordinate computation to a maintained client-side layout engine while preserving the current transport and rendering stack.

## What Changes
- Add a `build-web-ui` requirement that God-View visible node coordinates are computed on the client from backend topology semantics rather than being fully authored on the backend.
- Adopt an ELK-based client-side layout stage for the visible topology graph, including collapsed and expanded endpoint-cluster views.
- Keep the backend responsible for topology semantics, stable IDs, cluster membership, edge classes, expansion state, and transport payload generation.
- Preserve the existing Arrow transport, roaring bitmap state surfaces, and deck.gl renderer; only the layout stage moves.
- Require endpoint clusters to be represented as client-layout features with compact collapsed summaries and readable expanded fan or spiral placement that avoids obvious overlap.
- Require deterministic layout caching keyed by topology revision and cluster expansion state so the client does not recompute layout on every frame.
- Require reset/collapse interactions to rebuild the visible graph from collapsed cluster state instead of relying on stale backend coordinates.
- Add a migration path that allows the current backend coordinate fields to coexist temporarily while the client layout engine is introduced and validated.

## Impact
- Affected specs:
  - `build-web-ui`
- Affected code:
  - `elixir/web-ng/assets/js/lib/god_view/layout_topology_state_methods.js`
  - `elixir/web-ng/assets/js/lib/god_view/lifecycle_stream_snapshot_methods.js`
  - `elixir/web-ng/assets/js/lib/god_view/rendering_graph_core_methods.js`
  - `elixir/web-ng/assets/js/lib/god_view/rendering_graph_view_methods.js`
  - `elixir/web-ng/assets/js/lib/god_view/rendering_selection_methods.js`
  - `elixir/web-ng/assets/js/lib/god_view/lifecycle_bootstrap_event_reset_view_methods.js`
  - `elixir/web-ng/assets/js/lib/god_view/*` tests and fixtures
  - `elixir/web-ng/lib/serviceradar_web_ng/topology/god_view_stream.ex`
  - `elixir/web-ng/lib/serviceradar_web_ng_web/channels/topology_channel.ex`
  - `helm/serviceradar/values-demo.yaml` if debug tooling is re-enabled for rollout validation
- Related active changes:
  - `add-topology-endpoint-visibility`
  - `refactor-endpoint-cluster-feature-layout`
  - `refactor-topology-layout-stability-and-performance`
