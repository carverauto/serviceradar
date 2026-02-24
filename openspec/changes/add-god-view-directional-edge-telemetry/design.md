## Context
God-View edge telemetry is currently modeled as a single aggregate flow per canonical edge. Interface metrics in CNPG include directional signals (in/out), but the current pipeline sums those values and enriches only one side (`source + local_if_index`) for each edge. The UI can therefore animate only undirected flow unless direction is faked.

## Goals / Non-Goals
- Goals:
  - Provide real per-edge directional telemetry (A→B and B→A) end-to-end to God-View.
  - Eliminate synthetic frontend bidirectional splitting.
  - Preserve PoC-like packet stream readability (dense columns, tube alignment, zoom-appropriate visibility).
- Non-Goals:
  - Replacing topology discovery logic.
  - Introducing per-packet ground-truth direction beyond available interface telemetry.

## Decisions
- Decision: Extend edge telemetry contract with directional fields.
  - Add directional packet/bit rates (`flow_pps_ab`, `flow_pps_ba`, `flow_bps_ab`, `flow_bps_ba`) while retaining aggregate fields for compatibility.
- Decision: Keep canonical undirected topology edges, but attach both directional telemetry values to each canonical edge.
  - Directionality is telemetry metadata, not separate structural edges.
- Decision: UI renders bidirectional streams only when directional fields are present.
  - No synthetic 50/50 split fallback.
  - Missing side data yields single-direction rendering.

## Data Path Changes
1. Topology edge assembly (`god_view_stream.ex`):
   - Preserve both endpoint-side interface identifiers needed for directional telemetry lookups.
2. Telemetry enrichment (NIF `enrich_edges_telemetry`):
   - Resolve source-side and target-side directional rates where available.
   - Emit directional plus aggregate fields.
3. Snapshot encoding / decode:
   - Extend Arrow schema columns for directional fields.
4. Frontend rendering:
   - Consume directional fields in particle generation.
   - Render reverse lane only with real reverse telemetry.

## Risks / Trade-offs
- Risk: Many edges may have one-sided or missing interface mappings.
  - Mitigation: explicit fallback semantics and tests for one-sided/no-sided telemetry.
- Risk: Higher particle density can impact frame time.
  - Mitigation: maintain cacheing, caps, and zoom-tier attenuation.

## Migration Plan
1. Add directional fields in backend/NIF and keep aggregate fields unchanged.
2. Update decode path to populate directional fields.
3. Flip frontend to consume real directional fields and remove synthetic split.
4. Validate in demo namespace and tune particle profile.

## Open Questions
- Should directional packet counts be preferred over directional bit rates when one signal is missing?
- Should directional telemetry be exposed in tooltip/debug overlays for operator verification?
