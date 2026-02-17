# Change: Add causal topology signal pipeline and identity-layout boundaries

## Why
`prop2.md` identifies three recurring failure modes: topology identity collapse, unstable layout behavior under inferred edge fanout, and unclear causal signal ingestion boundaries for SIEM/BMP data. Existing proposals improve topology fidelity, but we still need explicit contracts for identity-vs-topology separation and causal signal routing into God-View overlays.

## What Changes
- Add discovery requirements that prohibit topology-link evidence from being used as device identity proof and require deterministic identity anchors for mapper outputs.
- Add observability signal requirements for normalized external causal signals (SIEM + BMP/BGP) with provenance, severity, and replay-safe event identity.
- Add a new `topology-causal-overlays` capability that separates structural layout from causal state overlays.
- Add a `prop2.md` traceability artifact that enumerates every actionable `prop2.md` item and maps each item to:
  - a spec requirement,
  - an implementation task,
  - and a final disposition (`implement`, `defer`, or `reject` with rationale).
- Define ingestion path boundaries for causal BMP data:
  - BMP messages are ingested via `BMP collector (risotto) -> NATS JetStream -> Elixir Broadway consumer`.
  - Existing agent gRPC streams remain for agent-originated payloads and are not the BMP ingress path.
- Require bounded overlay recomputation so frequent causal events do not trigger full topology layout recomputation.

## Scope from prop2.md
This proposal uses `prop2-traceability.md` as the authoritative scope ledger.

- In-scope now (`implement`): identity-vs-topology separation, deterministic identity anchors, confidence-tiered topology handling, normalized causal signal envelope, BMP ingestion via `risotto -> JetStream -> Broadway`, and overlay/layout separation with burst handling.
- Deferred (`defer`): larger mapper decomposition/refactors, advanced hypergraph/BGP causal extensions, and major snapshot/layout payload redesign.
- Rejected (`reject`): any BMP ingress model that depends on agent-originated gRPC streaming.

## Phased Delivery Plan
1. Contract phase:
   - Land spec-level guarantees for identity boundaries, causal signal normalization, and overlay/layout separation.
2. Pipeline phase:
   - Implement causal ingestion path (`risotto -> JetStream -> Broadway`) and idempotent normalization pipeline.
3. Overlay phase:
   - Ensure event-driven causal overlay updates do not force structural layout recomputation.
4. Verification phase:
   - Replay/burst tests and God-View stability validation under high-rate BMP signals.
5. Follow-up planning phase:
   - Spin out deferred `prop2.md` groups into dedicated follow-up changes.

## Acceptance Criteria
- Every `implement` item in `prop2-traceability.md` has completed task coverage and test evidence.
- No topology-adjacency-only evidence can cause device identity equivalence.
- BMP causal events flow through `risotto -> JetStream -> Broadway` and update overlays without agent-stream dependency.
- Causal bursts update classifications while topology coordinates remain stable for unchanged topology revision.
- `openspec validate add-causal-topology-signal-pipeline --strict` passes.

## Impact
- Affected specs:
  - `network-discovery`
  - `observability-signals`
  - `topology-causal-overlays` (new)
- Affected systems/code (expected):
  - `pkg/mapper/*` identity and topology evidence contracts
  - `elixir/serviceradar_core` Broadway consumers and causal signal normalization pipeline
  - `web-ng` topology snapshot/overlay orchestration
  - Rust NIF causal evaluation entry points used by topology overlays
  - `openspec/changes/add-causal-topology-signal-pipeline/prop2-traceability.md`
- Related active changes:
  - `improve-mapper-topology-fidelity`
  - `refactor-lldp-first-topology-and-route-analysis`
  - This proposal defines cross-component contracts those efforts can implement against.
