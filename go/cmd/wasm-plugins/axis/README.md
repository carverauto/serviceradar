# AXIS Camera Plugin

ServiceRadar TinyGo/WASM plugin for AXIS cameras via VAPIX.

## Current Scope
- Basic device identity polling (`basicdeviceinfo.cgi`)
- API discovery probe (`apidiscovery.cgi`)
- Stream endpoint discovery (profile/status probes + heuristic URLs)
- Stream endpoint discovery from real `streamprofile.cgi?list` profile parsing
- Optional AXIS websocket event collection (`/vapix/ws-data-stream`) mapped to OCSF events
  - Uses URL userinfo credentials through the host websocket bridge when credentials are configured
  - Supports comma/newline topic filters through `event_topic_filters`
- Emits `serviceradar.plugin_result.v1` summary/details plus canonical
  `serviceradar.metric.v1` telemetry for AXIS health metrics
- Includes a reference `stream_camera` entrypoint and `manifest.stream.json` for the new Wasm media host bridge
  - `stream_camera` now uses a narrow RTSP-over-TCP + interleaved RTP/H264 path suitable for AXIS main-stream relay
  - Current scope is intentionally narrow: H264 video over RTSP/TCP with basic auth handling and a single H264 video track
- Includes a narrow `goxis`-derived parser helper (`internal/axisref`) for key=value payload parsing

## Build

```bash
./build.sh
```

Output:
- `bazel-bin/build/wasm_plugins/axis_camera_bundle.zip`
- `bazel-bin/build/wasm_plugins/axis_camera_bundle.sha256`
- `bazel-bin/build/wasm_plugins/axis_camera_stream_bundle.zip`
- `bazel-bin/build/wasm_plugins/axis_camera_stream_bundle.sha256`

The same Wasm artifact exports both bundle variants:
- `run_check` for discovery/status/event polling
- `stream_camera` for the reference live-media bridge path

Each bundle contains the canonical import shape:
- `plugin.yaml`
- `plugin.wasm`
- optional `config.schema.json`

## Config

```json
{
  "host": "192.168.1.50",
  "scheme": "https",
  "username": "root",
  "password": "secret",
  "timeout": "10s",
  "discover_streams": true,
  "collect_events": false,
  "event_topic_filters": "tns1:VideoSource/Motion\ntns1:Device/IO/VirtualInput",
  "event_sources": "events"
}
```

## Stream Source Resolution

When a camera stream opens, the agent runs `run_check` with the host-owned
config key `_serviceradar_camera_source_resolution_request`
(`serviceradar.camera_source_resolution_request.v1`). The plugin then does no
inventory work: it reads `streamprofile.cgi?list` (one GET, because the media
parameters live on the camera), rebuilds the address the inventory reports for
the requested `vendor_profile_id` (an empty id selects the first profile), puts
the configured `username`/`password` in the URL userinfo, percent-encoded, and
submits only a `serviceradar.camera_source_resolution.v1` document. Without
configured credentials the address has no userinfo. An unknown profile is
`source_not_found`, HTTP 401/403 is `authentication_failed`, a host-reported
timeout is `connect_timeout`, and any other transport failure is
`connect_failed`. The failure detail never carries the address or a credential.

Inventory runs report stream addresses unless the assignment config carries
`"_serviceradar_camera_stream_addresses": "omit"`, which Core sets once it
opens streams through the resolver. With it, every stream and profile reports
`source_origin` (for example `rtsp://192.0.2.20`) and no media path,
`source_url`, `source_url_override` or raw VAPIX response bodies.

## Required Capabilities
- `get_config`
- `log`
- `submit_result`
- `http_request`
- `websocket_connect`
- `websocket_send`
- `websocket_recv`
- `websocket_close`

For the streaming package in `plugin.stream.yaml`, the required capabilities are:
- `get_config`
- `log`
- `camera_media_stream`
- `http_request`
- `tcp_connect`
- `tcp_read`
- `tcp_write`
- `tcp_close`

## Notes
- This plugin intentionally does not depend on full `goxis` runtime packages because they include ACAP/native/cgo paths that do not fit TinyGo/WASM constraints.
- The helper in `internal/axisref` is adapted from `goxis` (MIT) parsing logic only.
- A separate ServiceRadar `goxis` fork is not currently needed; the in-tree extracted helper is sufficient for the WASM-safe parsing surface we actually use.
- Compatibility notes are in `GOXIS_COMPATIBILITY.md`.
- Exact copied/adapted source provenance is listed in `EXTRACTION_MANIFEST.md`.
