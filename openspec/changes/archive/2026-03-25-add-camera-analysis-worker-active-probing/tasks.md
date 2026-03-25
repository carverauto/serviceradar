## 1. Probe Runtime
- [x] 1.1 Add a supervised active-probe manager for registered camera analysis workers.
- [x] 1.2 Probe enabled workers on a bounded interval with adapter-specific logic, starting with HTTP workers.
- [x] 1.3 Update registry health state, reasons, and timestamps from probe results.

## 2. Selection And Behavior
- [x] 2.1 Keep capability-based selection aligned with active probe health state.
- [x] 2.2 Keep explicit worker-id targeting fail-fast instead of silently rerouting.

## 3. Observability
- [x] 3.1 Emit telemetry for probe success, failure, and worker health transitions.
- [x] 3.2 Add focused tests for probing behavior and health-state updates.

## 4. Verification
- [x] 4.1 Validate the change with `openspec validate add-camera-analysis-worker-active-probing --strict`.
