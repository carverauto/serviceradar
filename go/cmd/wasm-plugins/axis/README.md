# AXIS Camera Plugin

ServiceRadar TinyGo/WASM plugin for AXIS cameras via VAPIX.

## Current Scope
- Basic device identity polling (`basicdeviceinfo.cgi`)
- API discovery probe (`apidiscovery.cgi`)
- Stream endpoint discovery (profile/status probes + heuristic URLs)
- Stream endpoint discovery from real `streamprofile.cgi?list` profile parsing
- Optional AXIS websocket event collection (`/vapix/ws-data-stream`) mapped to OCSF events
  - Uses WebSocket handshake headers for Authorization when credentials are configured
- Emits `serviceradar.plugin_result.v1` with metrics, summary, and JSON details
- Includes a narrow `goxis`-derived parser helper (`internal/axisref`) for key=value payload parsing

## Build

```bash
./build.sh
```

Output: `dist/plugin.wasm`

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
  "event_sources": "events"
}
```

## Required Capabilities
- `get_config`
- `log`
- `submit_result`
- `http_request`
- `websocket_connect`
- `websocket_send`
- `websocket_recv`
- `websocket_close`

## Notes
- This plugin intentionally does not depend on full `goxis` runtime packages because they include ACAP/native/cgo paths that do not fit TinyGo/WASM constraints.
- The helper in `internal/axisref` is adapted from `goxis` (MIT) parsing logic only.
