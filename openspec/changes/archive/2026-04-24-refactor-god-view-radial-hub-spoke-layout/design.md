## Context
The current God-View layout pipeline is structurally confused:

1. The default overview is not driven by one obvious geometry contract.
   `computeClientTopologyLayout/2` tries an ad hoc backbone-organic path for some graphs, but `requiresFullElkLayout/1` escalates to full ELK as soon as endpoint-summary/member nodes or endpoint-attachment edges are present.
2. The "organic radial" path is not a real hub-and-spoke algorithm.
   It builds a BFS tree, assigns angles from subtree weight, then relaxes with repulsion/springs. That is a reasonable experiment, but it is not a deterministic operational contract for cyclic transport graphs.
3. The graph semantics that affect geometry are too broad.
   `buildBackboneAdjacency/2` excludes only `endpoint-attachment`, so inferred/logical/hosted/observed relations can all pull on the default structure even when they should be overlays or diagnostics rather than backbone shape drivers.
4. There are still multiple leftover placement ideas in the code.
   Dead helpers such as `applyEndpointProjectionLayout/2` remain, and backend cluster nodes still carry authored coordinates even though backend layout authority is disabled.
5. Final geometry is still being heuristically distorted after layout.
   `normalizeHorizontalLayout/1` compresses the Y span after placement, which makes the final output differ from the algorithm that allegedly produced it.

This is why the topology surface feels arbitrary. Even when the code is deterministic, the operator-visible contract is not simple enough to reason about.

## Goals / Non-Goals
- Goals:
  - Make the default overview read like a deliberate radial hub-and-spoke topology.
  - Ensure only the bounded infrastructure backbone influences hub selection and radial tiering.
  - Keep endpoint fanout visible without letting it distort the backbone geometry.
  - Remove unused or competing placement paths from the default flow.
  - Make layout acceptance testable from operator-visible structure rather than from implementation details alone.
- Non-Goals:
  - Render every possible relation as part of the default radial backbone.
  - Preserve ELK as the default overview engine if it conflicts with the hub-and-spoke contract.
  - Solve every future topology mode in this one change; diagnostic and local-neighborhood views can still have different layout rules.

## Decisions

### Decision: The default overview uses one explicit radial hub-and-spoke contract
The default God-View overview SHALL choose one deterministic infrastructure hub/root and place promotable infrastructure nodes in radial depth tiers around it. The algorithm may use weighted ordering within a tier, but it SHALL not switch to a different primary geometry family just because endpoint nodes are present.

Consequences:
- Operators can predict what the graph is trying to communicate.
- Tests can assert radial tier behavior directly.

### Decision: Backbone placement inputs are strictly narrower than renderable edge inputs
Only promotable infrastructure transport relations may influence the default backbone coordinate solve. Endpoint-attachment edges, unresolved identity fragments, and purely diagnostic relations may still render, but only as anchored decorations or diagnostics after the backbone is placed.

Consequences:
- A leaf explosion cannot reclassify the entire graph into a different layout regime.
- The default overview reflects backbone connectivity first.

### Decision: Endpoint groups are anchored spoke decorations, not peers in the backbone solve
Collapsed endpoint summaries, expanded endpoint members, and similar fanout structures SHALL be positioned relative to their owning anchor after backbone geometry is established. They SHALL NOT trigger a full overview layout pass that treats them as first-class backbone vertices.

Consequences:
- Expanding a cluster becomes a local neighborhood operation instead of a global topology mutation.
- The backbone stays visually stable while fanout detail is explored.

### Decision: Remove geometry distortion and dead default-path placement helpers
The default overview path SHALL not run post-placement Y-axis squashing or leave dormant secondary projection helpers in the active code path. If a helper is not part of the chosen layout contract, it should be deleted or clearly isolated from the default flow.

Consequences:
- The geometry operators see matches the geometry the algorithm actually produced.
- Future debugging becomes tractable because there is one active placement story.

### Decision: ELK becomes optional, not implicit
ELK may still be retained for specialized local-neighborhood or diagnostic views if it proves useful there, but it SHALL NOT be the silent default fallback for endpoint-heavy overview graphs.

Consequences:
- The default overview remains simple and consistent.
- Advanced layout engines can still be evaluated in bounded contexts later.

## Risks / Trade-offs
- A true radial contract can under-represent certain mesh structures if tier ordering is too naive.
  Mitigation: use bounded within-tier ordering and explicit meshed-backbone regression fixtures.
- Stricter backbone-input filtering may hide some relations operators currently see by default.
  Mitigation: preserve those relations as overlays or drill-down diagnostics instead of default geometry drivers.
- Removing ELK fallback from the overview path may expose shortcomings in current topology role metadata.
  Mitigation: make missing-anchor or ambiguous-backbone conditions explicit in tests and quality signals.

## Migration Plan
1. Define the exact default-overview node/edge subset used for radial placement.
2. Implement deterministic hub selection and radial tier placement for infrastructure nodes.
3. Re-anchor endpoint summaries and expanded members as post-backbone spoke decorations.
4. Remove `normalizeHorizontalLayout/1` and any dead default-path endpoint projection remnants.
5. Keep optional ELK usage, if any, behind explicit non-overview modes only.
6. Add fixture-driven regression tests that prove the graph stays readable under endpoint fanout and cross-links.

## Open Questions
- Do we want one global radial hub or one radial hub per connected backbone component when multiple disjoint infrastructure islands exist?
- Should logical or hosted relations ever contribute to radial tiering, or should they always remain overlays unless explicitly promoted by backend semantics?
- Do we want an explicit diagnostics toggle that temporarily visualizes the filtered-out non-backbone relations without changing the default layout contract?
