## Context
God-View currently streams topology snapshots from `god_view_stream.ex` with coordinates already attached. That pipeline is responsible for layout, endpoint projection, cluster expansion, collision cleanup, snapshot revisioning, and cache behavior. It has become difficult to reason about because one subsystem owns both topology semantics and the final visual geometry.

The new direction is to keep the backend authoritative for topology meaning and interaction state, but move visible coordinate computation into the frontend with a maintained layout engine. The current stack already has the right rendering and transport pieces:
- Arrow payloads for compact graph transfer
- roaring bitmap state for selections, overlays, and other indexed visibility surfaces
- deck.gl for large-graph rendering

The missing piece is a layout engine that can treat endpoint clusters and the backbone as graph-layout concerns instead of backend geometry heuristics.

## Goals / Non-Goals
- Goals:
  - Move visible topology coordinate computation to the client.
  - Preserve Arrow transport, roaring bitmaps, and deck.gl.
  - Make expanded endpoint clusters readable and reversible.
  - Make layout caching explicit and deterministic.
  - Reduce geometry logic in `god_view_stream.ex` to graph semantics rather than final screen-space placement.
- Non-Goals:
  - Replacing deck.gl with a different renderer.
  - Replacing Arrow transport with JSON-only snapshots.
  - Rewriting topology discovery or canonical topology generation.
  - Delivering a full graph-editor framework migration in one step.

## Decisions
- Decision: Use an ELK-based client-side layout stage.
  - Why:
    - ELK is designed for graph layout, layering, spacing, and compound structures.
    - It fits our current renderer-first architecture better than adopting a full graph UI framework.
    - It lets us keep the existing deck.gl layers and interaction stack.
  - Alternatives considered:
    - Continue backend custom layout:
      - Rejected because it has already become a bespoke geometry engine with poor convergence on real graphs.
    - Replace God-View with Cytoscape.js:
      - Deferred because it would combine a layout migration and a renderer migration into one large change.
    - Use simpler layout libraries like dagre:
      - Rejected because endpoint-cluster placement and feature grouping need more than a simple DAG layout.

- Decision: Backend remains authoritative for semantics, not final coordinates.
  - Backend responsibilities:
    - node and edge identity
    - cluster membership and collapsed or expanded state
    - edge classes such as backbone versus endpoint attachment
    - transport payload versioning
    - stable revision identity inputs
  - Client responsibilities:
    - build visible graph for the current UI state
    - run layout for the visible graph
    - cache layout results by revision and expansion state
    - feed computed positions to deck.gl

- Decision: Endpoint clusters become first-class client-layout features.
  - Collapsed clusters are summary feature nodes.
  - Expanded clusters become feature subgraphs with deterministic local ordering and readable spacing.
  - The layout model must support a fan or spiral expansion pattern that stays visually tied to the cluster anchor without obvious self-overlap.

- Decision: Migrate incrementally.
  - The backend may continue to emit coordinates during transition.
  - The frontend can gate ELK layout behind a feature flag or topology option until validated.
  - Once validated, backend coordinates for God-View become compatibility data rather than layout authority.

## Risks / Trade-offs
- Client layout can become expensive on large graphs.
  - Mitigation:
    - cache by revision plus expanded cluster set
    - only recompute when visible topology semantics change
    - keep deck.gl rendering unchanged

- ELK may need topology-specific mapping logic for endpoint clusters.
  - Mitigation:
    - build a dedicated God-View graph adapter layer instead of leaking ELK structures throughout the UI
    - cover collapsed and expanded endpoint fixtures with deterministic frontend tests

- The transition period can create ambiguity about whether backend or frontend coordinates win.
  - Mitigation:
    - define a single client-side switch that selects layout authority
    - expose telemetry/logging for layout source during rollout

## Migration Plan
1. Add an OpenSpec requirement for client-side layout ownership and transport preservation.
2. Introduce a God-View client graph-adapter that maps decoded topology state into an ELK graph.
3. Add layout cache keys based on topology revision and expanded cluster state.
4. Feed ELK coordinates into existing deck.gl layers while retaining current selection and overlay behavior.
5. Reduce backend coordinate logic to compatibility mode and semantic grouping support.
6. Validate on demo with endpoint-heavy topologies before deleting legacy backend layout branches.

## Open Questions
- Whether ELK alone is sufficient for the desired endpoint-cluster spiral, or whether we need a small local pre-layout for cluster members before passing the graph to ELK.
- Whether the initial rollout should be guarded behind a user-visible God-View setting or only a developer feature flag.
