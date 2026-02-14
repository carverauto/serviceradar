## Context
Issue #2834 proposes a high-scale, causality-aware topology experience that unifies physical/logical relationships with incident blast-radius visualization. The existing UI has strong charting and topology foundations but lacks a single high-density rendering path and causal overlay model.

## Goals / Non-Goals
- Goals:
  - Provide a single operator view for large topology state with causal blast-radius overlays.
  - Keep causal decision logic server-side and rendering logic client-side.
  - Maintain low-latency interactions through binary transport and GPU-first rendering.
  - Minimize JavaScript main-thread object churn/GC pressure at 100k+ nodes.
- Non-Goals:
  - Replacing every existing dashboard in phase 1.
  - Full custom rendering engine from scratch if existing GPU-capable web stack components satisfy SLOs.
  - Introducing multitenancy routing or per-tenant topology partitions.

## Decisions
- Decision: Use versioned binary topology snapshots (Arrow IPC + metadata) as the canonical stream payload.
  - Alternatives considered: JSON/REST snapshots, protobuf-only row payloads.
  - Rationale: minimizes client parse overhead and supports direct typed buffer handling.
- Decision: Use `deck.gl` with WebGPU mode as the default God-View renderer on supported clients.
  - Alternatives considered: canvas-only custom rendering, WebGL-only baseline.
  - Rationale: `deck.gl` provides a mature high-density visualization stack while WebGPU offers the best path for throughput and latency targets.
- Decision: Implement hybrid filtering where backend emits causal state bitmaps and frontend applies visual states.
  - Alternatives considered: backend pre-filtered payload variants, frontend-only causal inference.
  - Rationale: preserves backend authority for causality while retaining interactive UI performance.
- Decision: Encode topology layout/state in Rust via Rustler NIF and pass Arrow-compatible buffers from Elixir orchestration.
  - Alternatives considered: Elixir-side binary packing as the long-term solution.
  - Rationale: Rust provides the required memory/layout control and performance characteristics for 100k+ node workloads.
- Decision: Add a Wasm client compute layer for Arrow buffer operations (filtering/traversal/interpolation), keeping per-node operations out of JavaScript where possible.
  - Alternatives considered: JS-only client compute over Arrow typed arrays.
  - Rationale: reduces GC pressure and frame-time jitter at 100k+ scale while preserving interactivity during heavy updates.
- Decision: Define explicit "structural reshape" operations that trigger backend recomputation.
  - Alternatives considered: making all reshapes purely client-driven.
  - Rationale: layout/collapse semantics for very large graphs require server-owned topology math.

## Risks / Trade-offs
- Rust NIF and Arrow integration adds complexity and operational debugging overhead.
  - Mitigation: schema versioning, decode validation tests, and fallback payload path.
- Large graph updates may exceed frame/update budgets on lower-end clients.
  - Mitigation: adaptive level-of-detail and bounded update cadence.
- Wasm integration increases frontend build/runtime complexity.
  - Mitigation: phase rollout (JS compatibility path first), strict perf gates, and fallback strategy.
- Causal attribution confidence may vary by telemetry completeness.
  - Mitigation: expose confidence and evidence fields in operator UX.

## Migration Plan
1. Ship backend snapshot and bitmap contract behind feature flag.
2. Ship web-ng God-View reader/renderer with fallback empty/error states.
3. Enable in demo/internal environments and measure SLO compliance.
4. Expand rollout after performance and reliability sign-off.

## Open Questions
- What minimum hardware/browser profile defines supported 60fps behavior?
- Which causal model outputs are mandatory in phase 1 versus deferred?
- What is the minimum viable Wasm surface for phase 1 (traversal only vs traversal + local scans + interpolation)?
