## Context
Issue #2834 proposes a high-scale, causality-aware topology experience that unifies physical/logical relationships with incident blast-radius visualization. The existing UI has strong charting and topology foundations but lacks a single high-density rendering path and causal overlay model.

## Goals / Non-Goals
- Goals:
  - Provide a single operator view for large topology state with causal blast-radius overlays.
  - Keep causal decision logic server-side and rendering logic client-side.
  - Maintain low-latency interactions through binary transport and GPU-first rendering.
- Non-Goals:
  - Replacing every existing dashboard in phase 1.
  - Full custom rendering engine from scratch if existing GPU-capable web stack components satisfy SLOs.
  - Introducing multitenancy routing or per-tenant topology partitions.

## Decisions
- Decision: Use versioned binary topology snapshots (Arrow IPC + metadata) as the canonical stream payload.
  - Alternatives considered: JSON/REST snapshots, protobuf-only row payloads.
  - Rationale: minimizes client parse overhead and supports direct typed buffer handling.
- Decision: Implement hybrid filtering where backend emits causal state bitmaps and frontend applies visual states.
  - Alternatives considered: backend pre-filtered payload variants, frontend-only causal inference.
  - Rationale: preserves backend authority for causality while retaining interactive UI performance.
- Decision: Define explicit "structural reshape" operations that trigger backend recomputation.
  - Alternatives considered: making all reshapes purely client-driven.
  - Rationale: layout/collapse semantics for very large graphs require server-owned topology math.

## Risks / Trade-offs
- Rust NIF and Arrow integration adds complexity and operational debugging overhead.
  - Mitigation: schema versioning, decode validation tests, and fallback payload path.
- Large graph updates may exceed frame/update budgets on lower-end clients.
  - Mitigation: adaptive level-of-detail and bounded update cadence.
- Causal attribution confidence may vary by telemetry completeness.
  - Mitigation: expose confidence and evidence fields in operator UX.

## Migration Plan
1. Ship backend snapshot and bitmap contract behind feature flag.
2. Ship web-ng God-View reader/renderer with fallback empty/error states.
3. Enable in demo/internal environments and measure SLO compliance.
4. Expand rollout after performance and reliability sign-off.

## Open Questions
- Which GPU rendering library and extension set will be the default in web-ng for phase 1?
- What minimum hardware/browser profile defines supported 60fps behavior?
- Which causal model outputs are mandatory in phase 1 versus deferred?
