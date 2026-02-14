## 1. Specification and Architecture
- [ ] 1.1 Confirm scope boundaries for phase 1 (topology + causal blast radius) versus later layers (full telemetry atmosphere).
- [ ] 1.2 Finalize binary snapshot schema (Arrow columns, metadata envelope, schema versioning).
- [ ] 1.3 Finalize causal classification contract (`root_cause`, `affected`, `healthy`, `unknown`) and explainability fields.

## 2. Backend Data and Causal Pipeline
- [ ] 2.1 Implement topology projection query path that produces stable node and edge identities for streaming.
- [x] 2.2 Implement snapshot builder/encoder in Rust NIF and expose it through Elixir orchestration.
- [ ] 2.3 Integrate causal engine evaluation into snapshot generation with deterministic fallback rules.
- [ ] 2.4 Emit compact bitmap metadata per snapshot revision for filter state.

## 3. Frontend Rendering and Interaction
- [x] 3.1 Implement God-View entry point in web-ng behind feature flag.
- [x] 3.2 Implement GPU-backed rendering pipeline that consumes binary snapshots without JSON fanout.
- [x] 3.3 Implement hybrid filter application (ghosting/highlight) and causal legend/state controls.
- [ ] 3.4 Implement semantic zoom transitions and topology reshape triggers for collapse/expand behavior.
- [ ] 3.5 Add Wasm Arrow execution path for local traversal and compound filtering at 100k+ scale.
- [ ] 3.6 Add Wasm-based coordinate interpolation path for large animated transitions.

## 4. Reliability and Observability
- [ ] 4.1 Add telemetry for snapshot build latency, payload size, frame timing, and dropped update counts.
- [ ] 4.2 Add backpressure/degradation behavior when targets exceed real-time budgets.
- [ ] 4.3 Add golden and integration tests for snapshot decoding, causal mask correctness, and UI fallback behavior.

## 5. Rollout
- [ ] 5.1 Roll out via feature flag to internal/demo environments first.
- [ ] 5.2 Validate performance SLOs on representative large datasets before broad enablement.
- [ ] 5.3 Publish operator-facing docs for controls, limitations, and troubleshooting.
