## 1. Registry And Runtime
- [x] 1.1 Add bounded recent probe history fields to the camera analysis worker model.
- [x] 1.2 Update the active probe manager to record recent probe outcomes on each worker.
- [x] 1.3 Keep probe history bounded and ordered newest-first.

## 2. Management Surface
- [x] 2.1 Expose recent probe history through the authenticated worker management API.
- [x] 2.2 Show recent probe activity and normalized failure reasons in the operator-facing worker surface.

## 3. Verification
- [x] 3.1 Add focused tests for probe history updates and API/UI exposure.
- [x] 3.2 Validate the change with `openspec validate add-camera-analysis-worker-probe-history-surface --strict`.
