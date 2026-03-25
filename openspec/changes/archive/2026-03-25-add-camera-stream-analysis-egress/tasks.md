## 1. Relay Analysis Contract
- [x] 1.1 Define relay-session-scoped analysis branches in `core-elx`.
- [x] 1.2 Define bounded extraction policies for frames, samples, or downscaled video artifacts.
- [x] 1.3 Ensure analysis consumers do not cause duplicate upstream camera pulls.

## 2. Worker and Event Integration
- [x] 2.1 Define the contract for sending analysis inputs to external workers.
- [x] 2.2 Define the contract for receiving detections or derived events back into platform state.
- [x] 2.3 Normalize analysis-derived outputs into observability/event surfaces.

## 3. Operational Guardrails
- [x] 3.1 Add limits and observability for analysis fan-out, sampling, and backpressure.
- [x] 3.2 Ensure viewer playback remains prioritized when analysis branches are active.
- [x] 3.3 Document Boombox as an optional implementation strategy rather than a required dependency.

## 4. Verification
- [x] 4.1 Add focused tests for analysis branch lifecycle and bounded extraction behavior.
- [x] 4.2 Validate the change with `openspec validate add-camera-stream-analysis-egress --strict`.
