## Context
The current God-View pipeline now preserves endpoint attachments through the backend snapshot path, but expanded endpoint clusters still use generic concentric/radial member placement around a cluster hub. That geometry is easy to compute but wrong for the problem: it treats a high-fanout endpoint feature as a bag of points instead of a topology feature with its own envelope, orientation, and local crossing constraints.

The user-visible result is predictable:
- collapsed endpoint groups can still exert too much pressure on nearby structure if their footprint is underestimated
- expanded endpoint groups fan out in a visually flat plane rather than a directed branch
- nearby backbone edges can cut through the expanded cluster because no local orientation pass tries to avoid them
- point-based collision cleanup can reshape the expanded feature after projection because the cleanup phase does not understand cluster envelopes
- expansion/collapse updates can be dropped or feel broken when expansion state is not treated as part of snapshot identity and reset semantics

The design should borrow the useful operational ideas from feature-based graph layout work such as Archambault et al.:
- collapse meaningful subgraphs into feature nodes for coarse layout
- assign feature-specific local layout instead of one generic geometry rule
- reserve area for expanded features before final compaction
- do local crossing reduction around each feature rather than destabilizing the entire graph

The repository also now contains `TopoMap-pp/`, which is relevant but not identical to the Tulip TopoLayout paper. `TopoMap-pp` is an MST-based projection method for point sets, not a direct implementation of our network-topology layout problem. That distinction matters. We should mirror the geometric primitives that transfer cleanly and reject the parts that depend on a point-cloud MST embedding model.

## Goals / Non-Goals
- Goals:
  - Keep the backbone layout readable and deterministic when endpoint attachments are present.
  - Make the backbone layout input explicitly structural so endpoint attachments cannot distort it.
  - Treat endpoint clusters as backend-authored topological features with explicit footprint.
  - Make expanded endpoint groups render as a readable fan/sector, not a generic ring.
  - Reduce overlap and local crossings between expanded endpoint members, their attachment edges, and nearby backbone geometry.
  - Preserve cluster feature shape through the post-projection cleanup phase.
  - Make expand/collapse state explicit, reversible, and visible to operators.
  - Reuse proven `TopoMap-pp` geometry operations where they fit instead of re-inventing the same transforms.
  - Preserve deterministic layout for unchanged topology revisions.
- Non-Goals:
  - Replacing the entire God-View layout engine with a full TopoLayout or TopoMap port.
  - Moving endpoint-cluster geometry into the frontend renderer.
  - Solving all graph-compaction problems outside endpoint cluster behavior.

## Decisions
- Decision: Backbone layout and endpoint-feature layout are separate phases with separate inputs.
  - Rationale: infrastructure topology and endpoint fanout have different geometry goals. The backbone should be laid out from structural links only. Endpoint attachment edges belong to feature projection after backbone coordinates already exist.

- Decision: Endpoint cluster geometry remains backend-authored.
  - Rationale: the backend already owns structural layout and revision-aware determinism; pushing expand/collapse geometry into the client would reintroduce layout divergence and make tests weaker.

- Decision: Expanded endpoint clusters use an anchored sector/fan layout instead of full-circle radial placement.
  - Rationale: endpoint attachments are semantically downstream from a specific infrastructure node. A directed fan preserves that meaning and leaves more freedom to orient the cluster away from congestion.

- Decision: Cluster placement is footprint-aware and envelope-aware.
  - Rationale: hub placement based only on node count or a fixed gap is too weak. The layout needs an estimated envelope for both collapsed and expanded states so the cluster can reserve enough space before final cleanup, and cleanup must treat the expanded cluster as one feature envelope instead of unrelated points.

- Decision: Use a bounded local orientation scorer instead of global recomputation.
  - Rationale: trying several candidate sector rotations around a hub is cheap, deterministic, and directly targets the real failure mode: member rays and nearby backbone edges competing for the same visual region.

- Decision: Expansion state participates in snapshot identity.
  - Rationale: if expanded/collapsed feature state does not change snapshot identity, valid backend updates can be dropped by the streaming client as unchanged revisions. Feature state is part of the rendered topology state and must therefore affect revision/caching semantics.

- Decision: Reset/collapse is a topology-state operation, not only a camera operation.
  - Rationale: operators need an obvious way to recover from an expanded cluster. Reset must be allowed to collapse expanded endpoint features before re-fitting the view, and the UI must surface collapse intent clearly.

- Decision: Mirror `TopoMap-pp` geometry helpers, not its entire MST embedding algorithm.
  - Rationale: the portable parts are the local geometric operations:
    - boundary-edge selection against a reference point (`closest_edge_point_simplices` in [utils.py](/home/mfreeman/serviceradar/TopoMap-pp/topomap/utils.py))
    - component rotation toward a target orientation (`find_angle`, `fix_rotation`, and `_rotate_component` in [TopoMap.py](/home/mfreeman/serviceradar/TopoMap-pp/topomap/TopoMap.py))
    - component translation to a precise attachment position (`_translate_component` in [TopoMap.py](/home/mfreeman/serviceradar/TopoMap-pp/topomap/TopoMap.py))
    - bounded feature blowout / footprint scaling (`_scale_component` in [HierarchicalTopoMap.py](/home/mfreeman/serviceradar/TopoMap-pp/topomap/HierarchicalTopoMap.py))
  - These map well to endpoint-cluster placement. The non-portable parts are MST construction, persistence-tree extraction, and full point-set projection, because our backbone layout already exists and our problem is local feature expansion.

- Decision: Determinism beats perfect global optimality.
  - Rationale: operators need stable mental maps more than marginal crossing improvements from non-deterministic search. The scorer should use a fixed candidate set and stable tie-breaking.

## Source Mapping
- Mirror directly:
  - reference-edge selection over a feature boundary
  - rotate-then-translate placement of a local feature relative to an anchor
  - bounded scaling of a feature envelope before final placement
- Adapt:
  - convex-hull and boundary logic from point components to endpoint-cluster envelopes
  - blowout scaling from persistence-driven components to endpoint-count and local-density driven footprints
  - component merge orientation into anchor-relative sector scoring against nearby backbone geometry
- Do not port directly:
  - MST construction and sorted-edge merge loop
  - persistence-tree component extraction as the driver of the whole layout
  - generic high-dimensional point projection

## Risks / Trade-offs
- Risk: Footprint reservation pushes clusters farther from anchors, increasing canvas area.
  - Mitigation: keep footprint estimates bounded and run a final compacting/proximity pass that respects reserved envelopes instead of flattening them.

- Risk: Local orientation scoring may still fail in extreme dense neighborhoods.
  - Mitigation: encode minimum spacing and conflict penalties in tests, and keep a fallback orientation that remains deterministic even when all candidates are imperfect.

- Risk: Splitting logic between Elixir and the native layout path could make behavior hard to reason about.
  - Mitigation: keep one authoritative placement pipeline and only move footprint/scoring into the native path if it materially improves performance or clarity.

- Risk: Additional state semantics for expansion/collapse can drift between channel, snapshot, and UI code.
  - Mitigation: add explicit revision-state and reset/collapse regression coverage so state transport failures are caught the same way geometry regressions are.

- Risk: "copy TopoMap" can become cargo-culting the wrong algorithm.
  - Mitigation: preserve a short source-mapping note in implementation docs/tests so every mirrored function has an explicit reason for existing in the ServiceRadar topology domain.

## Migration Plan
1. Land the spec contract for backend-owned endpoint cluster feature layout.
2. Make the backbone-layout invariant explicit by excluding endpoint attachments from the structural layout input and keeping cluster projection post-layout.
3. Replace the current expanded radial member placement with sector/fan geometry and explicit footprint estimation.
4. Mirror or adapt the selected `TopoMap-pp` geometry helpers inside the backend layout path.
5. Add local orientation scoring against nearby nodes and backbone edges.
6. Change post-projection cleanup so it preserves reserved feature envelopes rather than only resolving point collisions.
7. Make expansion state part of snapshot identity and ensure reset/collapse semantics are explicit end to end.
8. Expand regression coverage around spacing, angular spread, backbone preservation, determinism, and reversibility.
9. Validate against a representative endpoint-heavy topology before merging.

## Open Questions
- Should the footprint reservation and orientation scoring stay in Elixir for now, or move into the native layout layer once the behavior is proven?
- Should feature-envelope preservation be implemented as a separate cluster-aware cleanup pass, or by teaching the existing proximity/collision pass about cluster-owned nodes and reserved bounds?
- Do we want one sector-width heuristic for all endpoint clusters, or different policies based on member count and nearby backbone density?
