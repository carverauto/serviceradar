## 1. HTTP Worker Adapter
- [x] 1.1 Add a relay-scoped analysis dispatch manager in `core-elx`.
- [x] 1.2 Add a configurable HTTP adapter that POSTs `camera_analysis_input.v1` payloads to worker endpoints.
- [x] 1.3 Add bounded concurrency, timeout, and drop behavior for worker dispatch.

## 2. Result Integration
- [x] 2.1 Normalize successful worker HTTP responses through the existing analysis result contract.
- [x] 2.2 Ingest derived results into observability state with relay and worker provenance.
- [x] 2.3 Add explicit handling for malformed, timeout, and non-2xx worker responses.

## 3. Observability and Guardrails
- [x] 3.1 Emit telemetry for dispatch success, failure, timeout, and dropped work.
- [x] 3.2 Ensure adapter backpressure does not block viewer playback or upstream relay ingest.
- [x] 3.3 Document the HTTP adapter as a reference implementation, not a required transport.

## 4. Verification
- [x] 4.1 Add focused tests for bounded HTTP dispatch and result ingestion.
- [x] 4.2 Validate the change with `openspec validate add-camera-analysis-http-worker-adapter --strict`.
