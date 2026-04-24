## Context
Topology quality degrades when identity and adjacency heuristics are mixed. Separately, causal overlays become noisy when every external event rebuilds topology geometry. `prop2.md` also proposes a streaming ingress path for BMP events that conflicts with existing platform architecture.

## Goals / Non-Goals
- Goals:
  - Enforce identity-vs-topology separation in discovery contracts.
  - Standardize external causal signal ingestion for SIEM/BMP.
  - Preserve routing payload fidelity while producing a stable normalized causal envelope for query/overlay use.
  - Keep topology coordinates stable while causal overlays update at event rate.
  - Encode the canonical BMP ingestion path through risotto + JetStream + Broadway.
  - Ensure causal overlays consume AGE-authoritative topology context (`platform_graph`) and map cleanly into God-View atmosphere layers.
- Non-Goals:
  - Replacing current agent gRPC streams.
  - Replacing current topology storage/projection stack (CNPG + AGE).
  - Introducing multitenancy features.

## Decisions
- Decision: Identity proof cannot be derived from topology adjacency.
  - Rationale: adjacency is evidence of relationship, not of sameness.
- Decision: Causal signal ingestion uses event-bus semantics, not agent stream semantics, for BMP/SIEM.
  - Rationale: BMP/SIEM events are external, bursty, and replay-oriented; JetStream + Broadway provides durable consumption and backpressure handling.
- Decision: Persist both normalized causal envelope fields and raw routing payload.
  - Rationale: avoids schema lock-in; OCSF projection can evolve without losing source fidelity.
- Decision: Topology structure and causal overlays are evaluated in separate phases.
  - Rationale: layout churn from high-rate signals creates visual instability and unnecessary compute.
- Decision: Causal overlay evaluation is topology-authoritative via AGE graph projection.
  - Rationale: eliminates UI-side identity guessing and keeps causal adjacency reasoning aligned with canonical graph state.
- Decision: `prop2.md` is treated as a traceable source plan, and every actionable item must be mapped to implementation or explicit disposition.
  - Rationale: avoid silent scope drift or accidental omission from a detail-heavy plan.

## Risks / Trade-offs
- Risk: Duplicate behavior across active topology proposals.
  - Mitigation: keep this change focused on contracts and ingestion boundaries; reference related changes for implementation details.
- Risk: Event storms from BMP feeds could starve overlay processing.
  - Mitigation: require bounded consumer concurrency and coalescing windows in implementation tasks.

## Migration Plan
1. Add contract-level requirements in OpenSpec (this change).
2. Build and maintain `prop2-traceability.md` with one-to-one mapping from actionable `prop2.md` items.
3. Align mapper/core/web implementations under active topology and observability changes.
4. Roll out BMP/Broadway ingestion and verify overlay-only updates under replay load.

## Open Questions
- Which subject taxonomy should represent BMP events in JetStream (`bmp.events.*` vs namespaced tenant subjects)?
- Should SIEM and BMP use a shared causal event schema version or independent versions with a shared adapter layer?
