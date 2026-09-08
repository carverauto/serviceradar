## Context
The current camera relay and Wasm media bridge work for vendor paths that ultimately yield `rtsp://` sources over plain TCP. Live validation against a UniFi Protect 7.0.88 controller showed a different shape: API-key discovery is supported on the newer `/integration/v1` API and returns real per-camera `rtsps://` URLs, while the legacy bootstrap route fails with HTTP 500 for that auth mode. That means the supported discovery path for at least one vendor already ends in RTSP-over-TLS.

Today the shared SDK RTSP client and the Wasm plugin media loop assume plaintext RTSP over raw TCP host functions. The plugin can discover and resolve the right stream, but it cannot open it. This leaves the platform in an awkward state where the supported inventory path and the supported media path diverge.

## Goals
- Let streaming Wasm camera plugins consume `rtsps://` camera sources through the existing camera media bridge.
- Preserve the current relay/session/uploader architecture and avoid introducing a second media transport.
- Keep plaintext `rtsp://` support intact for existing vendors.
- Make the behavior deterministic and testable in both hermetic fixtures and gated live-controller smoke tests.

## Non-Goals
- Replacing the current camera relay session model.
- Replacing the edge-facing camera media gRPC contract.
- Converting camera streaming plugins into native-only readers.
- Solving every possible TLS/auth quirk for all vendors in the first slice.

## Decisions

### Decision 1: Extend the shared SDK RTSP client to support RTSP over TLS

**Choice**: The shared camera SDK SHALL support `rtsps://` endpoints in the same RTSP client abstraction used today for plaintext RTSP.

**Rationale**:
- Vendors such as UniFi Protect already expose supported media streams as `rtsps://`.
- Keeping one RTSP client abstraction reduces drift between plugin implementations.

### Decision 2: Reuse the existing Wasm media bridge rather than introducing a new one

**Choice**: Streaming plugins SHALL continue to use the existing `camera_media_open/write/heartbeat/close` host media bridge. RTSPS support SHALL be implemented below that layer in the SDK/runtime transport helpers.

**Rationale**:
- The current bridge already aligns with the relay session model.
- New host ABI surface is unnecessary for RTSP-over-TLS itself.

### Decision 3: Add TLS-capable outbound connection support at the host/runtime boundary only as needed

**Choice**: If the current TCP-only host transport is insufficient for Wasm plugins to perform RTSP-over-TLS, the agent runtime SHALL add the minimum host/runtime support necessary for TLS-protected camera transport and SHALL not alter the relay/session protocol.

**Rationale**:
- The real requirement is camera transport security, not a new media session model.
- This keeps the change scoped to source acquisition, not relay orchestration.

### Decision 4: UniFi Protect becomes the reference RTSPS plugin path

**Choice**: The UniFi Protect plugin SHALL be updated to treat integration-API RTSPS stream URLs as supported media sources once the shared RTSPS transport is available.

**Rationale**:
- Live controller validation already proved that this is the concrete vendor path we need to satisfy.
- It gives the shared change an immediate real-world consumer.

## Risks / Trade-offs
- **Wasm TLS complexity**
  - Mitigation: keep TLS support in shared SDK/runtime layers; avoid vendor-specific TLS logic in plugins.
- **Cert validation edge cases**
  - Mitigation: support the existing live-smoke insecure mode for validation, but keep normal verification strict by default.
- **Behavior drift between RTSP and RTSPS paths**
  - Mitigation: keep one parser/client surface and run the same depacketization/media-write tests across both.

## Migration Plan
1. Add OpenSpec deltas for RTSPS camera streaming support.
2. Extend the shared SDK/runtime transport path to open `rtsps://` sources.
3. Update the UniFi Protect plugin to accept real integration-API RTSPS URLs in `stream_camera`.
4. Add hermetic tests plus gated live-controller validation for the RTSPS path.
