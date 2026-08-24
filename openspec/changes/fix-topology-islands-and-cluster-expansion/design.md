## Context
The God-View snapshot pipeline has two disconnected fidelity problems that together produce the broken topology surface:

1. **Read-model projection drops real connectivity.** `RuntimeTopologyProjection.graph_projection_query/0` accepts backbone-plane rows only when the edge relation is `CONNECTS_TO`, `LOGICAL_PEER`, or `HOSTED_ON` (or relation is blank with `direct*`/`hosted-virtual` evidence). Canonical AGE edges of type `ATTACHED_TO` with `evidence_class = 'inferred-segment'` fail both the backbone branch and the attachment branch (which requires Interface-to-Interface rows from `mapper_topology_v1`). Demo data: 119 of 251 canonical Device-to-Device edges are `ATTACHED_TO/inferred-segment`; the SQL projection retains only 25 backbone rows touching 6 devices. The client-radial layout builds adjacency exclusively from backbone-class edges, so every device whose only canonical edge is an inferred-segment attachment renders as an island.
2. **Expansion semantics and geometry.** `TopologyChannel` enforces `@expanded_cluster_limit 1`: expanding cluster B replaces cluster A, which reads as "clusters don't expand". When expansion does happen, `expandedClusterGridMetrics/1` lays members on a fixed 240px-column grid offset by a constant pad, and `chooseExpandedClusterPlacement/4` scores candidate sides purely by counting nodes inside an axis-aligned rectangle plus a flat horizontal bonus. Edge crossings are never considered, so member edges sweep across the backbone ("nodes cross over each other").

## Goals / Non-Goals
- Goals:
  - Rendered topology preserves every connectivity path that exists in canonical AGE adjacency (no islands caused by read-model filtering).
  - Operators can expand several endpoint clusters concurrently and compare them.
  - Expanded clusters and attachment-only satellites occupy deterministic, collision-free space near their anchors without crossing unrelated edges.
- Non-Goals:
  - Changing discovery itself (FDB walks, Q-BRIDGE, UniFi clients) - owned by `fix-cross-subnet-topology-attachment`.
  - Backend-authored coordinates or replacing the single frontend layout pass (`refactor-topology-read-model-for-carrier-scale` remains the umbrella for budgets and single-layout-authority).
  - Selecting the final client geometry engine in this change; `refactor-god-view-elk-scene` supersedes the interim radial/spiral implementation while preserving this change's connectivity outcomes.

## Decisions
- **D1: Project inferred-segment Device-to-Device edges into the read model.** Add a third branch to `graph_projection_query/0` matching `(a:Device)-[r:CANONICAL_TOPOLOGY]->(b:Device)` where `type(r) = 'ATTACHED_TO'` and `r.evidence_class = 'inferred-segment'`, projected with `topology_plane: 'attachment'`. Alternative considered: promote them to backbone plane - rejected, they represent endpoint reachability, not infrastructure transit, and would distort backbone layout. Alternative: wait for upstream discovery fixes - rejected, the edges already exist in AGE; the read model should be faithful to canonical state now.
- **D2: Attachment-satellite placement on the client.** The interim implementation places devices whose only edges are attachment-plane rows around their anchor instead of letting them fall into unplaced residual lanes. The durable requirement is adjacency through one client geometry authority; `refactor-god-view-elk-scene` replaces the interim ring mechanics with compound ELK geometry.
- **D3: Concurrent expansion limit becomes configurable** (`@expanded_cluster_limit` default 4). Expanding a new cluster no longer resets the set; exceeding the limit collapses the oldest expansion. Snapshot size stays bounded by the per-cluster visible-member cap (24).
- **D4: Interim expanded-cluster geometry.** The first defect fix replaces the rigid grid with an Archimedean spiral and candidate scoring. The normative requirement is engine-neutral collision-safe grouping; `refactor-god-view-elk-scene` removes this interim second projection pass and makes one compound ELK scene authoritative.
- **D5: Barycenter leaf ordering in organic-radial.** When assigning children angular spans in `assignOrganicBackbonePositions`, order siblings by the mean angle of their already-placed neighbors (one barycenter pass) before span division to reduce crossings.

## Risks / Trade-offs
- Larger snapshots when multiple clusters expand -> bounded by visible-member cap per cluster and the existing payload telemetry alerting.
- Projection row growth (attachment rows +119) -> well under the 2,000 attachment-row cap; refresh transaction already full-delete/reinsert.
- Layout heuristics can regress visual tests -> reuse `improve-mapper-topology-fidelity` farm01/tonka01 fixtures for golden assertions once landed; add unit tests for spiral math independent of fixtures.
- Client-side crossing scoring cost O(members x edges) per candidate -> members are capped at 24 per cluster and candidates at 4; negligible.

## Migration Plan
1. Land core projection change + tests; run `refresh_from_graph` against demo and confirm island count drops to ~0 via the existing diagnostics query.
2. Land channel multi-expand change behind the existing god-view feature flag; verify two simultaneous expansions over the channel.
3. Land JS satellite + spiral layout with unit tests; verify against demo screenshots (before/after).
4. Rollback: revert JS changes restores previous layout; revert projection branch restores previous read model (islands return, no data loss).

## Open Questions
- Default concurrent expansion limit (proposal suggests 4) - confirm operator preference.
- Whether attachment-satellite rings should also apply to hosted-plane devices currently using `collectHostedTopologyIslands` (they already do); unify the two ring implementations?
