## 1. Sidecar Worker
- [x] 1.1 Add an executable Boombox-backed analysis sidecar or worker path.
- [x] 1.2 Define one bounded media handoff mode from relay-scoped Boombox branches into that worker.
- [x] 1.3 Keep worker attachment and teardown subordinate to relay branch lifecycle.

## 2. Result Path
- [x] 2.1 Return sidecar findings through the existing normalized analysis result contract.
- [x] 2.2 Preserve relay session, branch, and worker provenance through observability ingestion.

## 3. Verification
- [x] 3.1 Add focused end-to-end tests for the Boombox branch -> sidecar -> result ingestion path.
- [x] 3.2 Validate the change with `openspec validate add-boombox-camera-analysis-sidecar --strict`.
