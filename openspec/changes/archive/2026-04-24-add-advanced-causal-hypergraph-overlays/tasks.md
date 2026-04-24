## 0. Scope and Completion Gates
- [x] 0.1 Map in-scope deferred items (`P2-043`, `P2-044`, `P2-047`, `P2-050`) to implementation artifacts.
- [x] 0.2 Add evidence (tests/benchmarks/assertions) for each mapped item.
- [x] 0.3 Do not close this change unless every mapped item has evidence or explicit re-disposition rationale.

## 1. Causal Model Extensions
- [x] 1.1 Define grouped causal context contracts (security zone, BGP prefix group) in normalized signal envelope.
- [x] 1.2 Extend causal evaluation interfaces for grouped propagation with deterministic precedence.

## 2. Explainability and Safety
- [x] 2.1 Add explainability metadata for propagated causal outcomes.
- [x] 2.2 Add guardrails for event burst handling and bounded evaluation latency.

## 3. Verification
- [x] 3.1 Add replay tests for grouped propagation behavior.
- [x] 3.2 Add validation cases for conflicting signal precedence.
- [x] 3.3 Add guardrail tests for bounded grouped-context evaluation.
- [x] 3.4 Run `openspec validate add-advanced-causal-hypergraph-overlays --strict`.
