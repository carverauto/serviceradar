## 1. Signaling and Session Contract
- [ ] 1.1 Extend relay session/browser state to advertise WebRTC playback transport metadata alongside the existing websocket fallback.
- [ ] 1.2 Add authenticated signaling endpoints/messages for relay-scoped WebRTC offer/answer and ICE candidate exchange.
- [ ] 1.3 Keep viewer authorization, viewer count, and idle-close semantics tied to the existing relay session model.

## 2. Core Media Egress
- [ ] 2.1 Add a Membrane-backed WebRTC egress branch in `serviceradar_core_elx` that reuses the existing relay ingest pipeline.
- [ ] 2.2 Ensure multiple viewers of the same relay session reuse the same upstream ingest and do not create duplicate agent pulls.
- [ ] 2.3 Add relay-scoped cleanup so WebRTC viewer teardown and relay shutdown remain monotonic with the existing `opening -> active -> closing -> closed/failed` state machine.

## 3. Browser Integration
- [ ] 3.1 Update device-page and God-View viewers to prefer WebRTC when advertised and usable.
- [ ] 3.2 Keep the existing websocket viewer path as an explicit fallback during rollout.
- [ ] 3.3 Show explicit viewer-state messaging for WebRTC negotiation failures and fallback selection.

## 4. Operations and Verification
- [ ] 4.1 Add focused tests for signaling, relay-scoped viewer lifecycle, and fallback selection.
- [ ] 4.2 Add manual verification coverage for at least one device-page viewer and one God-View viewer using WebRTC.
- [ ] 4.3 Validate the change with `openspec validate add-membrane-webrtc-camera-viewer-egress --strict`.
