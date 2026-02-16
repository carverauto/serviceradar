# Change: Add advanced causal hypergraph overlays

## Why
`prop2.md` proposes advanced causal behavior (security-zone and BGP-prefix propagation) that is valuable but intentionally deferred from baseline ingestion/layout separation. This change captures that next phase explicitly.

## What Changes
- Extend causal overlay model to support grouped propagation contexts (for example security zones and BGP prefix groups).
- Define advanced causal evaluation contracts for multi-signal routing/security scenarios.
- Add explainability outputs for propagated causal decisions.

## Impact
- Affected specs:
  - `observability-signals`
- Expected code areas:
  - Elixir causal signal normalization/orchestration
  - Rust causal evaluation paths used by topology overlay pipeline
