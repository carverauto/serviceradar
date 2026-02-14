## 1. Specification and Architecture
- [x] 1.1 Confirm scope boundaries for phase 1 as full-stack delivery (topology + causal blast radius + telemetry atmosphere overlays), with predictive/autonomous workflows deferred.
- [x] 1.2 Finalize binary snapshot schema (Arrow columns, metadata envelope, schema versioning).
- [x] 1.3 Finalize causal classification contract (`root_cause`, `affected`, `healthy`, `unknown`) and explainability fields.

## 2. Backend Data and Causal Pipeline
- [x] 2.1 Implement topology projection query path that produces stable node and edge identities for streaming.
- [x] 2.2 Implement snapshot builder/encoder in Rust NIF and expose it through Elixir orchestration.
- [x] 2.3 Integrate DeepCausality-based causal engine evaluation into snapshot generation (Rust path only; no Elixir fallback engine).
- [x] 2.4 Emit compact bitmap metadata per snapshot revision for filter state.

## 3. Frontend Rendering and Interaction
- [x] 3.1 Implement God-View entry point in web-ng behind feature flag.
- [x] 3.2 Implement GPU-backed rendering pipeline that consumes binary snapshots without JSON fanout.
- [x] 3.3 Implement hybrid filter application (ghosting/highlight) and causal legend/state controls.
- [x] 3.4 Implement semantic zoom transitions and topology reshape triggers for collapse/expand behavior.
- [x] 3.5 Add Wasm Arrow execution path for local traversal and compound filtering at 100k+ scale.
- [x] 3.6 Add Wasm-based coordinate interpolation path for large animated transitions.

## 4. Reliability and Observability
- [x] 4.1 Add telemetry for snapshot build latency, payload size, frame timing, and dropped update counts.
- [x] 4.2 Add backpressure/degradation behavior when targets exceed real-time budgets.
- [x] 4.3 Add golden and integration tests for snapshot decoding, causal mask correctness, and UI fallback behavior.

## 5. Rollout
- [x] 5.1 Roll out via feature flag to internal/demo environments first.
- [x] 5.2 Validate performance SLOs on representative large datasets before broad enablement.
  - Validated on local Docker CNPG + web-ng (2026-02-14):
    - GodView snapshot build (`GodViewStream.latest_snapshot/0`, 20 runs): `p50=14.12ms`, `p95=35.26ms` after warm-up.
    - Synthetic 100k encode (`Native.encode_snapshot/8`): `33.96ms` for `100,000` nodes / `99,999` edges (`~4.8MB` payload).
    - Synthetic 100k causal evaluation (`Native.evaluate_causal_states/2`): `103.23ms` for `100,000` states.
  - Successful image build artifact: `make build-web-ng` => `//docker/images:web_ng_image_amd64`.
- [x] 5.3 Publish operator-facing docs for controls, limitations, and troubleshooting.
