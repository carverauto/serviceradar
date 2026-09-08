# Change: Add RTSPS Support for Camera Wasm Streaming

## Why
Live validation against a UniFi Protect 7.0.88 controller showed that API-key authenticated camera discovery works on the newer integration API and resolves real per-camera stream URLs, but those URLs are `rtsps://...` endpoints. The current Wasm media path only supports plaintext RTSP-over-TCP, so discovery succeeds while live media still cannot start for vendors that only expose RTSPS in their supported API surface.

## What Changes
- Add RTSP-over-TLS (`rtsps://`) support to the shared camera streaming path used by Wasm camera plugins.
- Extend the shared SDK and agent host bridge so streaming plugins can open TLS-protected camera streams without inventing a new relay transport.
- Update the UniFi Protect plugin to treat integration-API RTSPS URLs as a supported media source instead of a known stop point.
- Add hermetic tests and a gated live-controller validation path that prove RTSPS discovery and media bootstrap behavior.

## Impact
- Affected specs:
  - `camera-streaming`
  - `wasm-plugin-system`
  - `edge-architecture`
- Affected code:
  - `go/cmd/wasm-plugins/unifi-protect`
  - `go/cmd/wasm-plugins/axis` if shared RTSP/TLS helpers move into the SDK
  - `/Users/mfreeman/src/serviceradar-sdk-go/sdk`
  - `go/pkg/agent/plugin_runtime.go`
