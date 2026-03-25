# AXIS `goxis` Extraction Manifest

This plugin does not take a runtime dependency on `goxis`.

Only the narrow parsing logic below was copied/adapted for TinyGo/WASM-safe use:

| Source Repository | Source Path | Target Path | Notes |
| --- | --- | --- | --- |
| `github.com/Cacsjep/goxis` | `pkg/vapix/VapixParsers.go` | `go/cmd/wasm-plugins/axis/internal/axisref/vapix_parsers.go` | Adapted key/value and stream-profile parsing helpers only. |

Explicitly excluded from this extraction:

- `pkg/axevent/**`
- `pkg/dbus/**`
- all packages using `import "C"`
- all transport implementations that bypass the ServiceRadar SDK host ABI

The AXIS plugin owns all HTTP, WebSocket, and RTSP I/O through `serviceradar-sdk-go`.
