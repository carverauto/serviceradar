## Context
God-View edge telemetry is currently modeled as a single aggregate flow per canonical edge. Interface metrics in CNPG include directional signals (in/out), but the current pipeline sums those values and enriches only one side (`source + local_if_index`) for each edge. The UI can therefore animate only undirected flow unless direction is faked.

## Goals / Non-Goals
- Goals:
  - Provide real per-edge directional telemetry (A→B and B→A) end-to-end to God-View.
  - Eliminate synthetic frontend bidirectional splitting.
  - Preserve PoC-like packet stream readability (dense columns, tube alignment, zoom-appropriate visibility).
  - Reuse existing `ifIn*` / `ifOut*` metrics without adding new collection pipelines.
  - Ensure topology-linked interfaces are telemetry-eligible by default (no manual per-interface enablement required for core link metrics).
- Non-Goals:
  - Replacing topology discovery logic.
  - Introducing per-packet ground-truth direction beyond available interface telemetry.

## Decisions
- Decision: Extend edge telemetry contract with directional fields.
  - Add directional packet/bit rates (`flow_pps_ab`, `flow_pps_ba`, `flow_bps_ab`, `flow_bps_ba`) while retaining aggregate fields for compatibility.
- Decision: Directional values are derived from existing interface counters mapped to each edge endpoint.
  - For a canonical edge `A <-> B`, use endpoint-attributed interface counters to compute:
    - `A -> B` from A-side egress and/or B-side ingress signals.
    - `B -> A` from B-side egress and/or A-side ingress signals.
  - When only one side is available, publish only that directional side and keep the opposite side empty/zero.
- Decision: Keep canonical undirected topology edges, but attach both directional telemetry values to each canonical edge.
  - Directionality is telemetry metadata, not separate structural edges.
- Decision: SNMP topology evidence is authoritative for telemetry-bearing edges.
  - Prefer LLDP/CDP/SNMP-L2 edges with valid interface attribution for edge telemetry mapping.
  - UniFi-API edges without interface attribution remain valid structural/discovery edges but are explicitly telemetry-ineligible.
- Decision: UI renders bidirectional streams only when directional fields are present.
  - No synthetic 50/50 split fallback.
  - Missing side data yields single-direction rendering.
- Decision: Add discovery-level metric bootstrap control for topology telemetry coverage.
  - Mapper/discovery SHALL support an option (default enabled) that ensures topology-relevant interfaces receive at least octet and packet counters needed for God-View.
  - Coverage applies to interfaces implicated by topology links and may be reconciled periodically to repair drift.
## Data Path Changes
1. Topology edge assembly (`god_view_stream.ex`):
   - Preserve both endpoint-side interface identifiers needed for directional telemetry lookups.
   - Normalize endpoint attribution so canonical ordering does not invert telemetry semantics.
2. Telemetry enrichment (NIF `enrich_edges_telemetry`):
   - Resolve source-side and target-side directional rates where available from existing interface counters.
   - Emit directional plus aggregate fields.
3. Snapshot encoding / decode:
   - Extend Arrow schema columns for directional fields.
4. Discovery/polling bootstrap:
   - Ensure topology-linked interfaces have required SNMP OID configs (`ifIn/OutOctets`, `ifIn/OutUcastPkts`, HC variants when available).
   - Add a mapper/discovery setting to control this behavior.
5. Frontend rendering:
   - Consume directional fields in particle generation.
   - Render reverse lane only with real reverse telemetry.

## Risks / Trade-offs
- Risk: Many edges may have one-sided or missing interface mappings.
  - Mitigation: explicit fallback semantics and tests for one-sided/no-sided telemetry.
- Risk: Interface index/identity mismatch can map counters to the wrong direction.
  - Mitigation: add deterministic endpoint mapping tests and debug fields/logging for validation in demo.
- Risk: UniFi/API-derived links without interface identifiers remain unmappable to SNMP interface counters.
  - Mitigation: treat these as telemetry-ineligible and prefer SNMP-attributed links for telemetry-bearing rendering.
- Risk: Higher particle density can impact frame time.
  - Mitigation: maintain cacheing, caps, and zoom-tier attenuation.

## Migration Plan
1. Add directional fields in backend/NIF and keep aggregate fields unchanged.
2. Add endpoint mapping validation to ensure directional attribution uses the correct interface per side.
3. Update decode path to populate directional fields.
4. Flip frontend to consume real directional fields and remove synthetic split.
5. Validate in demo namespace and tune particle profile.

## Open Questions
- Should directional packet counts be preferred over directional bit rates when one signal is missing?
- Should directional telemetry be exposed in tooltip/debug overlays for operator verification?
