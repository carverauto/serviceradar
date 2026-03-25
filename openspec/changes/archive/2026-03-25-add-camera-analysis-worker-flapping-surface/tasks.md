## 1. Runtime And Registry
- [x] 1.1 Add derived flapping fields to the camera analysis worker model.
- [x] 1.2 Recompute flapping state when recent probe history is updated.
- [x] 1.3 Emit telemetry when workers enter or leave flapping state.

## 2. Management Surface
- [x] 2.1 Expose flapping state and normalized flapping metadata through the worker management API.
- [x] 2.2 Show flapping state prominently in the camera analysis worker operator surface.

## 3. Verification
- [x] 3.1 Add focused tests for flapping derivation, telemetry, and API/UI exposure.
- [x] 3.2 Validate the change with `openspec validate add-camera-analysis-worker-flapping-surface --strict`.
