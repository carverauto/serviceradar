## 1. Plugin Package
- [x] 1.1 Create `go/cmd/wasm-plugins/unifi-protect` scaffold (`main.go`, `go.mod`, `build.sh`, `manifest.json`, `manifest.stream.json`, `README.md`).
- [x] 1.2 Reuse the shared camera SDK config, HTTP, websocket, RTSP, and media bridge helpers from `serviceradar-sdk-go`.
- [x] 1.3 Ensure the package builds under TinyGo/WASM with the existing plugin runtime.

## 2. Protect Inventory and Discovery
- [x] 2.1 Implement Protect controller authentication/session bootstrap needed for camera API access.
- [x] 2.2 Implement camera inventory polling and normalized device identity metadata output.
- [x] 2.3 Implement stream descriptor discovery and normalized camera stream profile output.
- [x] 2.4 Emit Protect camera descriptors in the existing plugin result enrichment contract.

## 3. Events and Streaming
- [x] 3.1 Implement Protect event collection and map relevant events to OCSF-compatible payloads.
- [x] 3.2 Implement `stream_camera` using the shared camera media bridge and vendor-specific stream bootstrap logic.
- [x] 3.3 Ensure streaming uses the existing relay/media bridge path without adding new host functions.

## 4. Tests and Verification
- [x] 4.1 Add unit tests for Protect API parsing, descriptor normalization, and event mapping.
- [x] 4.2 Add streaming-path tests covering stream bootstrap and media bridge interaction.
- [x] 4.3 Run `go test ./...` in `go/cmd/wasm-plugins/unifi-protect`.
- [x] 4.4 Run TinyGo WASM build verification for the Protect plugin.
- [x] 4.5 Run `openspec validate add-unifi-protect-camera-wasm-plugin --strict`.
