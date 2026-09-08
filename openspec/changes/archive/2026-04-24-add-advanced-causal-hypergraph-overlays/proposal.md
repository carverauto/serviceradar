# Change: Add advanced causal hypergraph overlays

## Why
`prop2.md` proposes advanced causal behavior (security-zone and BGP-prefix propagation) that is valuable but intentionally deferred from baseline ingestion/layout separation. This change captures that next phase explicitly.

## What Changes
- Extend causal overlay model to support grouped propagation contexts (for example security zones and BGP prefix groups).
- Define advanced causal evaluation contracts for multi-signal routing/security scenarios.
- Add explainability outputs for propagated causal decisions.
- Add explicit bounded-latency/guardrail behavior for grouped causal evaluation.

## Impact
- Affected specs:
  - `observability-signals`
- Expected code areas:
  - Elixir causal signal normalization/orchestration
  - Rust causal evaluation paths used by topology overlay pipeline

## In-Scope Deferred Items (prop2 Traceability)
- `P2-043` Security/BGP hyperedge-style grouped propagation model
- `P2-044` Extended causal node/context schema
- `P2-047` Advanced causality evaluation contract for grouped routing/security signals
- `P2-050` BGP group source integration contract (limited to normalized input contract in this change)

## Out of Scope
- Risotto BMP publication implementation (`2.1` in `add-causal-topology-signal-pipeline`)
- Topology layout algorithm refactors (covered by `refactor-topology-layout-stability-and-performance`)
- Mapper discovery pipeline decomposition (covered by `refactor-mapper-discovery-pipeline-boundaries`)

## Definition of Done
- Every in-scope `P2-*` item has implementation evidence or explicit re-disposition rationale.
- Causal signal normalization supports grouped contexts (security zone and BGP prefix groups).
- Explainability metadata for propagated outcomes is emitted and test-covered.
- Conflicting signal precedence behavior is deterministic and test-covered.
- Grouped-evaluation guardrails enforce bounded context size and bounded processing behavior.

## Implementation Traceability (P2 -> Artifact -> Evidence)
| P2 ID | Disposition | Implementation Artifacts | Evidence |
|---|---|---|---|
| `P2-043` | partial implement | `elixir/serviceradar_core/lib/serviceradar/event_writer/processors/causal_signals.ex` | Grouped context normalization for `security_zone` and `bgp_prefix_group` references |
| `P2-044` | partial implement | `elixir/serviceradar_core/lib/serviceradar/event_writer/processors/causal_signals.ex` | Envelope now includes grouped contexts + explainability + guardrail metadata |
| `P2-047` | partial implement | `elixir/serviceradar_core/lib/serviceradar/event_writer/processors/causal_signals.ex` | Deterministic precedence resolution (`primary_domain`) across conflicting signal domains |
| `P2-050` | deferred (data-source integration) | n/a | This change defines/normalizes BGP group input contract; authoritative BGP source integration remains deferred |

## Verification Evidence
- `elixir/serviceradar_core/test/serviceradar/event_writer/processors/causal_signals_test.exs`
  - grouped context + explainability normalization test
  - guardrail truncation test
  - grouped replay determinism and precedence test
