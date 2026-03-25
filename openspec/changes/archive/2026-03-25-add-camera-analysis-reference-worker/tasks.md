## 1. Reference Worker
- [x] 1.1 Add a small HTTP analysis worker that accepts `camera_analysis_input.v1`.
- [x] 1.2 Return deterministic `camera_analysis_result.v1` payloads derived from input metadata.
- [x] 1.3 Document the worker as a reference implementation only.

## 2. End-to-End Validation
- [x] 2.1 Add an end-to-end test from analysis branch to HTTP worker to result ingestion.
- [x] 2.2 Verify derived events preserve relay session, branch, and worker provenance.
- [x] 2.3 Verify non-keyframe or unsupported inputs can return bounded no-op or empty results.

## 3. Verification
- [x] 3.1 Add focused tests for the reference worker request/response contract.
- [x] 3.2 Validate the change with `openspec validate add-camera-analysis-reference-worker --strict`.
