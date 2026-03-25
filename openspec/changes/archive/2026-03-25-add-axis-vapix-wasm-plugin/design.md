## Context
We are implementing AXIS camera support as a TinyGo/WASM plugin (not a new long-running daemon). The plugin runs inside the existing ServiceRadar WASM sandbox and must use host functions exposed by the agent runtime (`http_request`, `tcp_*`, `websocket_*`, etc.) through `serviceradar-sdk-go`.

The key architectural gap is not basic polling. It is the missing contract from plugin-discovered camera data to canonical device records and UI surfaces (especially discovered RTSP streams + auth metadata).

## Goals / Non-Goals
- Goals:
  - Build a production AXIS VAPIX plugin in `go/cmd/wasm-plugins/axis`.
  - Collect high-value camera telemetry/metadata using VAPIX endpoints available over HTTP(S)/WebSocket.
  - Persist discovered stream metadata as device enrichment and expose it in UI.
  - Route AXIS-originated events into ServiceRadar’s event processor path in OCSF form.
  - Keep credentials secure via secret references and non-secret metadata in result payloads.
- Non-Goals:
  - Running ACAP-native code on the camera.
  - Shipping full `goxis` ACAP wrappers into TinyGo WASM.
  - Storing plaintext camera passwords in plugin result payloads or device records.

## VAPIX Deep Dive (Targeted Endpoints)
Primary endpoint families to use from the plugin:

1. Discovery and capabilities
- `GET /axis-cgi/basicdeviceinfo.cgi` (`method=getAllProperties` / selected properties)
  - identity fields: serial number, product number, MAC, firmware version, architecture/model fields.
- `GET /axis-cgi/apidiscovery.cgi`
  - identify API groups and versions exposed by device.
- `GET /axis-cgi/param.cgi?action=list&group=Properties.*`
  - fallback capability interrogation where structured APIs are not available.

2. Stream discovery and status
- `GET /axis-cgi/streamprofile.cgi` (list profiles)
  - enumerate named profiles and map to stream URLs/options.
- `GET /axis-cgi/streamstatus.cgi`
  - active stream/session counters and client-facing status telemetry.
- `GET /axis-cgi/param.cgi` groups for RTSP/video settings
  - extract auth mode signals and transport capability hints.

3. Event collection
- `WS /vapix/ws-data-stream` (event stream configuration + notifications)
  - subscribe to selected event topics and transform to OCSF events.

## Authentication and Credential Handling
- Plugin config SHALL support:
  - `username` + `password_secret_ref` (preferred),
  - optional per-device override credentials,
  - TLS mode and certificate behavior flags for HTTPS.
- Plugin result/device enrichment SHALL NOT include raw secrets.
- For discovered RTSP streams:
  - persist endpoint metadata and auth requirements (`none`, `basic`, `digest`, `unknown`),
  - persist credential reference IDs only when configured,
  - do not persist resolved password values.

## `goxis` Usage Strategy
- `goxis` is MIT-licensed and valuable for endpoint semantics, field naming, and event mapping references.
- Direct use in TinyGo/WASM is high risk because `goxis` is oriented around ACAP/native SDK use and modern Go runtime dependencies; many packages rely on capabilities unavailable in TinyGo/WASM.
- Decision:
  - do not take a hard dependency on `goxis` runtime packages in the plugin MVP,
  - optionally copy/adapt tiny pure-Go VAPIX parsing helpers (with attribution) where TinyGo-compatible,
  - keep an explicit compatibility matrix before importing any package.

### Compatibility Matrix (from local clone `go/cmd/wasm-plugins/goxis`)
- Unsafe for TinyGo/WASM plugin runtime:
  - `pkg/axevent/**` uses cgo (`import "C"`) and GLib-backed Axis native APIs.
  - `pkg/dbus/dbus.go` depends on `github.com/godbus/dbus/v5` and Axis system bus.
  - `pkg/axvdo/**`, `pkg/axoverlay/**`, `pkg/axstorage/**`, `pkg/axparameter/**`, `pkg/axlarod/**`, `pkg/axlicense/**` rely on native C/OS APIs.
- Potentially reusable with adaptation:
  - `pkg/vapix/VapixParsers.go` pure parsing helpers (`key=value`, JSON response decoding).
  - Small portions of `pkg/vapix/Vapix.go` request/response structs and endpoint naming.
- Must be reimplemented against `serviceradar-sdk-go` host ABI:
  - HTTP transport currently built on direct `net/http` client in goxis.
  - WebSocket metadata client in `pkg/vapix/WebsocketMetadata.go` (currently uses direct gorilla dial + D-Bus credential lookup).
  - Any auth/header handling that depends on direct socket/WebSocket dial behavior.

### Narrow Fork Decision
- Current decision: do not create a dedicated ServiceRadar `goxis` fork for this change.
- Reason:
  - the current in-tree extraction in `go/cmd/wasm-plugins/axis/internal/axisref` covers the only helper logic we actually need,
  - the extracted scope is small enough that a separate maintained fork would add packaging and maintenance overhead without reducing runtime risk,
  - all transport, auth, and relay behavior already lives in ServiceRadar-owned SDK/runtime code.
- Revisit threshold:
  - create a dedicated fork only if future AXIS work needs a materially larger pure-Go parsing/model subset that is reused across multiple packages and still remains TinyGo/WASM-safe.

## Device Enrichment Data Contract
Introduce an optional `device_enrichment` block inside plugin results:
- `identity`:
  - candidate keys (`ip`, `mac`, serial, hostname) used to resolve canonical device.
- `camera`:
  - vendor/model/firmware/capabilities.
- `streams[]`:
  - stream ID/profile name,
  - URL template or normalized endpoint,
  - protocol (`rtsp`, `http`, `https`),
  - transport flags,
  - auth mode,
  - credential reference ID (optional).
- `source`:
  - plugin ID/version, observed timestamp, confidence/ttl.

Core ingestion behavior:
- resolve canonical device via DIRE-compatible identifiers,
- upsert stream observations in platform schema,
- expire stale stream observations by TTL,
- expose latest stream observations in device detail APIs.

## AXIS Event Pipeline Contract
- Plugin maps VAPIX WS event notifications into OCSF Event Log Activity objects.
- Events are carried via plugin payload and promoted into the standard events processor path.
- If dedicated plugin telemetry RPC is present, use it; otherwise process events from plugin result payload until telemetry pipeline is complete.
- `goxis/pkg/axevent` is used as a schema/topic reference only for event vocabulary, not as runtime code in WASM.

## Risks / Trade-offs
- TinyGo compatibility pressure can limit dependency reuse.
  - Mitigation: keep plugin HTTP/JSON code minimal and SDK-first.
- Endpoint variability across AXIS firmware versions.
  - Mitigation: capability detection first, feature flags per endpoint family, graceful partial success.
- Device identity ambiguity when only IP is available.
  - Mitigation: include multi-signal identity keys and confidence scoring; avoid destructive overwrites.
- Event volume spikes from camera streams.
  - Mitigation: event topic filtering, rate limits, and bounded batch sizes.

## Migration Plan
1. Ship plugin package + configuration schema.
2. Enable enrichment parsing in core (behind feature flag).
3. Add device stream UI exposure.
4. Enable event promotion path for AXIS events.
5. Roll out to pilot gateways and tune endpoint coverage + rate limits.

## Open Questions
- Should plugin event promotion rely only on plugin result payloads initially, or require plugin telemetry RPC readiness as a gate?
- Do we need a dedicated `camera_streams` table, or should stream observations live in an existing extensible enrichment table?
- What is the minimum secure secret-reference mechanism for plugin credentials in assignments/config UI?
- Do we standardize RTSP auth negotiation in plugin logic now, or only publish stream/auth metadata and defer active RTSP session validation?
