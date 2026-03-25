# Change: Add UniFi Protect TinyGo/WASM camera plugin

## Why
GitHub issue [#2916](https://github.com/carverauto/serviceradar/issues/2916) called out Ubiquiti camera support as a core part of the camera relay work. We now have the shared camera plugin SDK surface, the streaming media bridge, and the internal relay transport needed to support another vendor-specific camera plugin without inventing a new runtime path.

Without a UniFi Protect plugin, ServiceRadar still lacks a first-class way to discover Protect cameras, normalize their stream metadata, surface Protect events, and source live media through the existing agent relay path.

## What Changes
- Add a new TinyGo/WASM plugin implementation at `go/cmd/wasm-plugins/unifi-protect`.
- Implement Protect controller inventory polling for cameras, stream descriptors, and device identity metadata.
- Implement a Protect streaming entrypoint that reuses the shared camera SDK surface (`camera_http`, `websocket`, `camera_media`, `rtsp`) and the existing agent relay bridge.
- Normalize Protect-discovered camera and stream metadata into the same plugin result/enrichment contracts used by the existing camera relay pipeline.
- Map relevant Protect events into OCSF-compatible event payloads for downstream ingestion.
- Reuse the existing Wasm host ABI and shared SDK helpers; do not add a new media transport or plugin runtime mode.

## Impact
- Affected specs:
  - `unifi-protect-camera-plugin` (new)
  - `device-inventory` (modified)
- Affected code:
  - `go/cmd/wasm-plugins/unifi-protect/**` (new)
  - `serviceradar-sdk-go/sdk/**` only if Protect needs additional vendor-neutral helpers
  - plugin packaging/build wiring for the new WASM artifact
- Dependencies:
  - UniFi Protect controller HTTP/WebSocket APIs
  - existing camera relay/media bridge path already implemented in agent/gateway/core-elx
