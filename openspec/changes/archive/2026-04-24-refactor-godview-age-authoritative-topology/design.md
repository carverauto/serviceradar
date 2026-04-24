## Context
Topology evidence quality differs by device and protocol (LLDP/CDP/SNMP-L2/UniFi), and frontend currently performs corrective logic (candidate selection, directional fallback) to keep visualization alive. This has created brittle behavior and repeated regressions.

## Goals / Non-Goals
- Goals:
  - Make backend/AGE the single source of truth for graph structure and directional edge telemetry.
  - Eliminate frontend topology inference and edge arbitration logic.
  - Preserve directional packet-flow rendering using backend-provided fields only.
- Non-Goals:
  - Replacing Apache AGE.
  - Replacing deck.gl rendering primitives.

## Decisions
- Decision: Canonical edge contract from backend
  - Backend emits directional fields and interface attribution for every edge candidate accepted into AGE.
  - Frontend consumes only canonical edge rows.

- Decision: Reconciler-owned edge selection
  - Candidate ranking between LLDP/CDP/SNMP-L2/UniFi evidence is performed in backend reconciliation.
  - Frontend must not run pair-candidate ranking.

- Decision: Backend diagnostics
  - Reconciler emits reason codes when an edge is downgraded to fallback telemetry or marked unresolved.

## Risks / Trade-offs
- During migration, removing frontend rescue logic may temporarily reduce displayed animated edges.
  - Mitigation: dual-path shadow validation and cutover SLO gates.

## Migration Plan
1. Add canonical AGE edge projection fields + query API contract.
2. Keep existing frontend path in shadow mode and compare edge/telemetry parity.
3. Remove frontend candidate-selection/inference path.
4. Enforce backend-only topology edge contract.

## Open Questions
- Final source precedence table for conflicting direct evidence (LLDP vs CDP vs SNMP-L2) when interface attribution differs.
