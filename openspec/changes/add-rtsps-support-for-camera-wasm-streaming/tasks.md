## 1. Shared Transport
- [x] 1.1 Extend the shared camera SDK transport layer to recognize and parse `rtsps://` source URLs.
- [x] 1.2 Add the runtime/host support needed for Wasm camera plugins to open TLS-protected camera streams without changing the relay/media bridge contract.
- [x] 1.3 Keep plaintext `rtsp://` behavior unchanged and covered by regression tests.

## 2. UniFi Protect Plugin
- [x] 2.1 Update `stream_camera` to accept integration-API `rtsps://` stream URLs as supported sources.
- [x] 2.2 Remove the current “RTSPS not yet supported” stop point once the shared transport exists.
- [x] 2.3 Re-validate real controller API-key stream resolution against a live Protect controller.

## 3. Tests and Verification
- [x] 3.1 Add hermetic tests for RTSPS URL handling and transport bootstrap.
- [x] 3.2 Add or extend live-controller smoke validation to prove RTSPS stream bootstrap with a real Protect controller.
- [x] 3.3 Run `go test ./...` in `go/cmd/wasm-plugins/unifi-protect`.
- [x] 3.4 Run TinyGo WASM build verification for the Protect plugin.
- [x] 3.5 Run `openspec validate add-rtsps-support-for-camera-wasm-streaming --strict`.
