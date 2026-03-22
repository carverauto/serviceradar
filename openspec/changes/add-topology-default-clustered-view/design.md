## Context
God-View currently treats every visible endpoint attachment as a first-class rendered node. That is correct for drill-down, but it is a poor default for dense real networks where one access device may have dozens of downstream leaves. The user feedback from the live demo is clear: the default graph is now visually unreadable even though the underlying endpoint recovery work succeeded.

The main constraint is architectural, not cosmetic: frontend code must not decide topology layout or invent cluster membership. The backend snapshot is the contract. Any clustering strategy therefore has to be authored in the backend projection and represented explicitly in the streamed snapshot.

## Goals
- Preserve discovered endpoints while making the default topology view readable.
- Keep the backbone structure primary in the default view.
- Keep backend ownership of cluster membership, aggregate metadata, and coordinates.
- Support explicit operator drill-down from a cluster to member endpoints.

## Non-Goals
- Replace the existing endpoint layer with permanent aggregation only.
- Add frontend-only clustering or frontend-authored layout rules.
- Solve all possible topology simplification cases in one change; this proposal focuses first on dense endpoint attachments.

## Proposed Approach
1. Introduce backend-authored endpoint cluster nodes in the God-View snapshot.
   - A cluster node represents multiple discovered endpoint attachments associated with the same infrastructure anchor or attachment summary bucket.
   - The snapshot carries stable cluster IDs, aggregate counts, summarized health/state, and backend-authored coordinates.

2. Make clustered endpoint summaries the default rendering mode.
   - When the topology contains dense endpoint attachments, the default snapshot renders one or more cluster nodes instead of every endpoint leaf.
   - Backbone infrastructure nodes and links remain first-class and continue to drive the primary layout.

3. Support explicit expansion of a cluster.
   - Operators can request expansion for a cluster to reveal its member endpoints.
   - Expansion is a backend state/input that produces a new snapshot; the frontend does not compute expansion geometry locally.
   - Expanded endpoints are arranged by the backend in a spiral or radial fan-out around the owning infrastructure device or cluster origin so drill-down spreads leaves out while preserving the surrounding backbone layout.

4. Keep layer semantics coherent.
   - `endpoints` off hides clustered summaries and expanded endpoint leaves.
   - `endpoints` on shows clustered summaries by default.
   - Cluster expansion is subordinate to endpoint visibility, not a separate implicit layer.

## Snapshot Contract Additions
- Cluster nodes should expose enough metadata for rendering and operator comprehension:
  - stable cluster identifier
  - cluster member count
  - cluster kind / summary type
  - representative label text
  - summarized state / health rollup
  - optional representative sample values for detail panels
- Cluster edges should remain explicit topology edges in the snapshot so rendering code does not infer hidden relationships.
- Expanded cluster member coordinates should be explicit in the snapshot and SHALL reflect the backend-authored spiral expansion geometry.

## Open Questions
- Whether dense endpoint summaries should bucket strictly by anchor or allow multiple clusters per anchor for large mixed populations.
- Whether expansion is single-cluster-at-a-time or supports multiple simultaneously expanded clusters in one snapshot.
- How much member detail should be available in the initial cluster node payload versus fetched lazily on expansion.
