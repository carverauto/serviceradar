## 1. Relay Analysis Contract
- [ ] 1.1 Define relay-session-scoped analysis branches in `core-elx`.
- [ ] 1.2 Define bounded extraction policies for frames, samples, or downscaled video artifacts.
- [ ] 1.3 Ensure analysis consumers do not cause duplicate upstream camera pulls.

## 2. Worker and Event Integration
- [ ] 2.1 Define the contract for sending analysis inputs to external workers.
- [ ] 2.2 Define the contract for receiving detections or derived events back into platform state.
- [ ] 2.3 Normalize analysis-derived outputs into observability/event surfaces.

## 3. Operational Guardrails
- [ ] 3.1 Add limits and observability for analysis fan-out, sampling, and backpressure.
- [ ] 3.2 Ensure viewer playback remains prioritized when analysis branches are active.
- [ ] 3.3 Document Boombox as an optional implementation strategy rather than a required dependency.

## 4. Verification
- [ ] 4.1 Add focused tests for analysis branch lifecycle and bounded extraction behavior.
- [ ] 4.2 Validate the change with `openspec validate add-camera-stream-analysis-egress --strict`.
