# Change: Add AXIS VAPIX TinyGo/WASM plugin and device enrichment path

## Why
GitHub issue [#2887](https://github.com/carverauto/serviceradar/issues/2887) requests AXIS camera support via the WASM plugin system. We can already run TinyGo plugins with network host functions, but we do not yet have a defined contract for plugin-discovered camera streams and authentication metadata to become first-class device data in ServiceRadar.

Without that contract, an AXIS plugin can only emit service-style checks. Operators cannot reliably see discovered RTSP stream details in device UI, and AXIS metadata/event signals cannot be promoted into the observability event pipeline in a consistent, secure way.

## What Changes
- Add a new TinyGo plugin implementation at `go/cmd/wasm-plugins/axis` using `serviceradar-sdk-go` and VAPIX APIs.
- Define an AXIS capability spec for:
  - camera inventory polling (model, firmware, serial, capabilities),
  - stream discovery (RTSP/HTTP endpoints and profile metadata),
  - runtime health metrics (uptime, storage, stream/session status where available),
  - AXIS event extraction and mapping to OCSF event payloads.
- Extend plugin result ingestion to support optional device enrichment blocks and event emission from `serviceradar.plugin_result.v1` payloads.
- Add a secure plugin configuration pattern for credentials (secret references, not plaintext replay in result payloads) including RTSP authentication mode metadata.
- Define UI/data-contract behavior so discovered stream data is visible in device views.
- Document dependency strategy for `goxis`:
  - use `pkg/vapix` and `pkg/axevent` as API/field mapping references,
  - avoid direct runtime dependency in TinyGo/WASM unless a minimal TinyGo-compatible subset is carved out,
  - allow a ServiceRadar-maintained fork that strips ACAP/native-only code and exposes a WASM-safe Axis VAPIX/event mapping package.

## Impact
- Affected specs:
  - `axis-camera-plugin` (new)
  - `wasm-plugin-system` (modified)
  - `device-inventory` (modified)
  - `plugin-configuration-ui` (modified)
- Affected code:
  - `go/cmd/wasm-plugins/axis/**`
  - `go/pkg/agent/plugin_runtime.go` (if host ABI additions are required)
  - `elixir/serviceradar_core/lib/serviceradar/observability/plugin_result_ingestor.ex`
  - relevant Ash resources/APIs for device enrichment + stream metadata
  - plugin settings UI surfaces in `elixir/web-ng/**`
- External references:
  - AXIS VAPIX docs: https://developer.axis.com/vapix/
  - `goxis` repo: https://github.com/Cacsjep/goxis
  - `goxis` axevent package: https://pkg.go.dev/github.com/Cacsjep/goxis/pkg/axevent
