## 1. Gateway/Core Transport Refactor
- [x] 1.1 Add a `core-elx` camera relay ingress boundary that returns a per-session ERTS ingress target for open/upload/heartbeat/close.
- [x] 1.2 Replace `serviceradar-agent-gateway` camera media gRPC forwarding with ERTS-native forwarding to the `core-elx` ingress boundary.
- [x] 1.3 Remove the gateway-side dependency on an internal gRPC client for camera media forwarding while preserving the edge-facing camera media proto.
- [x] 1.4 Add negotiation and drain-path tests for the ERTS-native gateway/core handoff.

## 2. Wasm Streaming Runtime
- [x] 2.1 Add a separate agent-side streaming plugin mode for long-lived camera media sessions.
- [x] 2.2 Add Wasm host functions for media session lifecycle and binary media chunk writes.
- [x] 2.3 Back the Wasm media host bridge with the same native uploader used by non-plugin camera relay sources.
- [x] 2.4 Add capability gating, admission control, and resource limits specific to streaming plugins.

## 3. Plugin and Relay Integration
- [x] 3.1 Define assignment/config semantics for streaming plugins so the agent can start them with camera relay context.
- [x] 3.2 Keep descriptor/event/status ingestion on `plugin_result` while explicitly excluding live media from that path.
- [x] 3.3 Add at least one reference camera plugin path that uses the streaming media bridge.

## 4. Verification
- [x] 4.1 Add end-to-end tests for `agent -> gateway gRPC -> core-elx ERTS ingress` negotiation and chunk flow.
- [x] 4.2 Add integration coverage for a wazero streaming plugin opening, writing, heartbeating, and closing a relay session.
- [x] 4.3 Add failure/drain/cancellation tests for relay close, lease expiry, and plugin termination.
