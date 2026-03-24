## Context
The AXIS plugin and the shared camera SDK surface now cover the generic pieces a camera plugin needs: camera config loading, HTTP access, websocket access, RTSP/TCP media transport, and the Wasm camera media bridge. UniFi Protect should be implemented as a vendor plugin on top of that shared layer instead of adding new host functions or a separate runtime path.

## Goals
- Add a UniFi Protect camera plugin package that supports both discovery and streaming.
- Reuse the shared SDK helpers wherever the logic is not vendor-specific.
- Normalize Protect camera descriptors, stream metadata, and events into existing ingestion contracts.

## Non-Goals
- Replacing the current camera relay architecture.
- Adding a new plugin runtime mode or host ABI.
- Solving every Protect deployment variant in the first slice.

## Decisions
- Use a separate plugin package under `go/cmd/wasm-plugins/unifi-protect` rather than folding Protect into the AXIS plugin.
- Keep Protect controller/API semantics in the plugin, but route HTTP, websocket, RTSP, and media bridge behavior through `serviceradar-sdk-go`.
- Ship both a discovery/status manifest and a streaming manifest if Protect needs separate assignment behavior, matching the AXIS pattern.

## Risks / Trade-offs
- Protect auth/session behavior may require controller-specific cookie/token handling that is broader than the current AXIS basic/digest path.
  - Mitigation: keep auth/session logic plugin-local while preserving the shared SDK transport layer.
- Protect stream URL/bootstrap flows may differ by controller version and deployment mode.
  - Mitigation: start with a narrow, well-documented supported path and add fixtures/tests for observed variants.

## Migration Plan
1. Add the new plugin package and manifests.
2. Implement inventory + stream descriptor discovery.
3. Implement streaming entrypoint using the shared camera media bridge.
4. Add controller/API fixture tests and TinyGo build verification.
