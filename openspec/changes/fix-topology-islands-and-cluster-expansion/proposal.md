# Change: Fix topology islands and endpoint-cluster expansion

## Why
The God-View topology surface on the demo environment renders 44% of devices as islands (104 of 237 devices have no backbone or attachment edge in the rendered snapshot; status bar shows `bb:24` against 251 canonical `CANONICAL_TOPOLOGY` device-to-device edges in AGE). The SQL read-model projection drops Device-to-Device `ATTACHED_TO`/`inferred-segment` edges, so devices whose only connectivity is an inferred L2 segment lose their only path to the graph. Endpoint clusters also effectively cannot expand: the channel enforces `@expanded_cluster_limit 1`, so expanding a second cluster silently collapses the first, and when a cluster does expand, members are placed on a rigid grid scored only by axis-aligned node overlap, producing overlapping nodes and crossing edges.

## What Changes
- Make the runtime-topology SQL read-model projection complete relative to canonical AGE adjacency: Device-to-Device `ATTACHED_TO` edges with `inferred-segment` evidence are projected as attachment-plane rows instead of being dropped.
- Anchor devices whose only connectivity is an endpoint attachment in the anchor's connected client-layout neighborhood instead of routing them to unplaced residual lanes.
- Support multiple concurrently expanded endpoint clusters (configurable limit, default >= 3) without silently collapsing earlier expansions; keep expansion state stable across snapshot revisions.
- Replace the expanded-cluster rigid grid with deterministic collision-safe placement; the interim spiral implementation is superseded by the compound ELK scene change before final geometry rollout.
- Order backbone leaves by neighbor barycenter during the organic-radial layout pass to reduce edge crossings.

## Impact
- Affected specs: `age-graph`, `topology-god-view`
- Affected code:
  - `elixir/serviceradar_core/lib/serviceradar/network_discovery/runtime_topology_projection.ex` (projection query completeness)
  - `elixir/web-ng/lib/serviceradar_web_ng/topology/god_view_stream.ex` (attachment-anchor metadata for island devices)
  - `elixir/web-ng/lib/serviceradar_web_ng_web/channels/topology_channel.ex` (concurrent expansion limit)
  - `elixir/web-ng/assets/js/lib/god_view/layout_topology_state_methods.js` (satellite placement, spiral cluster layout, barycenter ordering)

## Dependencies
- The upstream discovery-level root causes (cross-subnet FDB joins, Q-BRIDGE walks, UniFi wired clients) remain owned by `fix-cross-subnet-topology-attachment`; this change makes the read model faithful to the edges AGE already stores so the rendered surface stops inventing islands from data it already has.
- Coordinates with `refactor-topology-read-model-for-carrier-scale`, which targets the same files but is unstarted (0/15). This change delivers the concrete defect fixes first and does not introduce backend layout authority; carrier-scale budgets can layer on top later.
- At post-deployment archive time, archive this change before `refactor-god-view-elk-scene`; its placement requirements are engine-neutral so the follow-up can replace interim radial/spiral code without contradicting the connectivity contract.

## Verification (demo evidence)
- `platform.runtime_topology_links` (demo CNPG): 25 backbone rows touching 6 distinct devices vs 251 `CANONICAL_TOPOLOGY` Device-to-Device edges in AGE (`ATTACHED_TO/inferred-segment`: 119).
- AGE device census: 237 devices; 104 (44%) have no `CANONICAL_TOPOLOGY` and no `MTR_PATH` edge reachable through the projected read model.
