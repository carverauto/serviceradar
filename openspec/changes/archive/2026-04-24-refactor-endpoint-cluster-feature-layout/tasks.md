## 1. Spec and Layout Contract
- [x] 1.1 Define backend-owned endpoint cluster layout requirements in `build-web-ui`, covering collapsed summaries, expanded fanout geometry, and deterministic orientation.
- [x] 1.2 Confirm the new contract extends `add-topology-endpoint-visibility` and `refactor-topology-layout-stability-and-performance` without redefining their broader scope.
- [x] 1.3 Record which `TopoMap-pp` primitives will be mirrored directly, which will be adapted, and which are out of scope because they solve point-cloud MST embedding instead of graph feature layout.
- [x] 1.4 Document the failure modes explicitly: backbone distortion, envelope-free expansion, point-level cleanup reshaping the feature, and dropped/opaque expand-collapse state.

## 2. Backend Feature Layout
- [x] 2.1 Make the backbone-layout invariant explicit: structural layout input excludes endpoint attachment edges and cluster projection happens after backbone coordinates are finalized.
- [x] 2.2 Replace generic expanded endpoint radial placement with an anchored sector/fan layout in the God-View snapshot pipeline.
- [x] 2.3 Compute an explicit footprint for collapsed and expanded endpoint clusters and use that footprint when projecting cluster geometry away from nearby backbone nodes and edges.
- [x] 2.4 Add a bounded local orientation/crossing-reduction pass that scores candidate sector rotations against nearby topology and chooses the lowest-conflict layout.
- [x] 2.5 Mirror the relevant `TopoMap-pp` geometry helpers for component-boundary choice and rotate/translate alignment in ServiceRadar's backend layout path.
- [x] 2.6 Preserve cluster feature envelopes through the post-projection cleanup phase instead of allowing point-level collision cleanup to collapse the fan back into a flat bundle.
- [x] 2.7 Preserve backend coordinate authority so frontend expand/collapse rendering consumes emitted coordinates without client-side re-layout.

## 3. Transport and Interaction
- [x] 3.1 Make expansion state part of snapshot revision/cache identity so expand/collapse/reset updates are never dropped as unchanged topology.
- [x] 3.2 Ensure cluster expand/collapse remains reversible through explicit channel/UI affordances rather than hidden click-path discovery.
- [x] 3.3 Define reset behavior so it can collapse expanded endpoint clusters before re-fitting the view.

## 4. Verification
- [x] 4.1 Add backend regression tests for backbone preservation, expanded angular spread, minimum member spacing, and overlap avoidance near nearby backbone edges.
- [x] 4.2 Add deterministic-layout regression coverage so identical topology revisions yield the same endpoint-cluster orientation and member geometry.
- [x] 4.3 Add state-transport regression coverage so expanded/collapsed snapshots have distinct revision identity and reset/collapse semantics remain functional.
- [ ] 4.4 Validate the issue scenario with a representative endpoint-heavy topology or replay and capture evidence that expanded clusters fan out without collapsing the backbone.
- [x] 4.5 Run `openspec validate refactor-endpoint-cluster-feature-layout --strict`.
