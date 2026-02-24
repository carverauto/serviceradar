## 1. Spec and Contract Alignment
- [ ] 1.1 Add `network-discovery` requirements for directional topology edge telemetry fields (`*_ab`, `*_ba`) and fallback semantics when only one side is available.
- [ ] 1.2 Add `build-web-ui` requirements for God-View directional rendering and PoC-like particle density/tube-fill behavior.
- [ ] 1.3 Validate the change with `openspec validate add-god-view-directional-edge-telemetry --strict`.

## 2. Backend Directional Telemetry Pipeline
- [ ] 2.1 Update topology edge enrichment to preserve directional packet/bit rates per edge side instead of only aggregate values.
- [ ] 2.2 Extend NIF telemetry structs and Arrow snapshot schema to encode/decode directional edge fields.
- [ ] 2.3 Ensure canonical edge deduplication preserves both directional values on the merged edge object.
- [ ] 2.4 Add regression tests for: both-sided telemetry, one-sided telemetry, and absent directional telemetry.

## 3. God-View Frontend Rendering
- [ ] 3.1 Remove synthetic bidirectional flow splitting and render reverse streams only when real directional fields exist.
- [ ] 3.2 Implement directional lane rendering using real telemetry ratios while preserving single-direction fallback.
- [ ] 3.3 Tune particle generation to maintain PoC-like density and tube coverage across zoom tiers.
- [ ] 3.4 Add/adjust tests for directional rendering behavior and density constraints.

## 4. Verification in Demo Namespace
- [ ] 4.1 Verify directional metric availability per topology edge side in demo CNPG (`timeseries_metrics` + mapper topology links).
- [ ] 4.2 Validate God-View behavior in demo: no fake bidi, correct directional rendering on eligible edges, graceful fallback on incomplete edges.
