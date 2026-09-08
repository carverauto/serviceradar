# `goxis` TinyGo/WASM Compatibility Notes

The AXIS plugin intentionally does not depend on `goxis` at runtime.

Compatibility findings:

- Unsafe for TinyGo/WASM:
  - packages using `import "C"`
  - D-Bus integrations such as `github.com/godbus/dbus/v5`
  - ACAP/native wrappers and direct transport stacks that bypass ServiceRadar host functions
- Reusable with adaptation:
  - narrow pure-Go VAPIX response parsing helpers
  - request/response field names and topic vocabulary as reference material
- Reimplemented in ServiceRadar:
  - HTTP transport through `serviceradar-sdk-go`
  - WebSocket event transport through `serviceradar-sdk-go`
  - RTSP/relay streaming through the shared SDK transport layer

Guardrails in this plugin package:

- extracted helper code is limited to `internal/axisref`
- compatibility tests reject `import "C"`, D-Bus imports, and gorilla websocket imports in `internal/axisref`
- the plugin package is verified with `tinygo build -target=wasi`

This keeps the AXIS plugin WASM-safe while still preserving attribution and endpoint semantics from `goxis`.

Current decision:

- a dedicated ServiceRadar-maintained `goxis` fork is not needed for this plugin change
- the in-tree `internal/axisref` extraction is sufficient for the currently reused TinyGo-safe parsing surface
