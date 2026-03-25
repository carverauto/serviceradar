## 1. Registry Model
- [x] 1.1 Add worker probe configuration fields to the camera analysis worker model.
- [x] 1.2 Keep bounded defaults for workers that do not specify probe overrides.

## 2. Management Surface
- [x] 2.1 Expose probe configuration through the authenticated worker management API.
- [x] 2.2 Expose probe configuration through the operator-facing `web-ng` worker management surface.
- [x] 2.3 Validate and normalize probe settings on create and update.

## 3. Runtime Integration
- [x] 3.1 Update the active probe manager and HTTP probe path to use registry-managed probe settings.
- [x] 3.2 Add focused tests for probe configuration management and runtime usage.

## 4. Verification
- [x] 4.1 Validate the change with `openspec validate add-camera-analysis-worker-probe-management --strict`.
