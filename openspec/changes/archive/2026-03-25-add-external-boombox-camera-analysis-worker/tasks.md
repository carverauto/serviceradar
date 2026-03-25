## 1. Worker Boundary
- [x] 1.1 Add an executable external Boombox-backed worker path.
- [x] 1.2 Define one bounded relay-derived media handoff mode from `core-elx` to that worker.
- [x] 1.3 Keep worker lifecycle subordinate to relay analysis branch lifecycle.

## 2. Result Path
- [x] 2.1 Return worker findings through the existing normalized analysis result contract.
- [x] 2.2 Preserve relay session, branch, and worker provenance through observability ingestion.

## 3. Verification
- [x] 3.1 Add focused end-to-end tests for relay branch -> external worker -> result ingestion.
- [x] 3.2 Validate the change with `openspec validate add-external-boombox-camera-analysis-worker --strict`.
