## 1. Axis Plugin Package
- [x] 1.1 Create `go/cmd/wasm-plugins/axis` scaffold (`main.go`, `go.mod`, `build.sh`, `manifest.json`, `README.md`).
- [x] 1.2 Implement VAPIX HTTP client wrappers using `serviceradar-sdk-go` host HTTP APIs.
- [x] 1.3 Implement capability discovery + basic device info collection.
- [x] 1.4 Implement stream profile/status discovery and normalized stream metadata output.
- [x] 1.5 Implement health metrics extraction and threshold mapping to plugin status.

## 2. Event Collection
- [x] 2.1 Implement AXIS event ingestion from VAPIX websocket stream with configurable topic filters.
- [x] 2.2 Map AXIS event payloads to OCSF Event Log Activity structures.
- [x] 2.3 Wire mapped events into plugin telemetry/result ingestion path so events reach the event processor pipeline.

## 3. Device Enrichment Path
- [x] 3.1 Extend plugin result ingestion to parse optional `device_enrichment` payloads.
- [x] 3.2 Resolve canonical device IDs for enrichment updates using existing identity signals.
- [x] 3.3 Persist discovered stream metadata in platform schema with source and freshness metadata.
- [x] 3.4 Expose stream metadata in device APIs and UI.

## 4. Security and Configuration
- [x] 4.1 Define plugin config schema for credentials using secret references.
- [x] 4.2 Ensure result payloads redact/omit secret material.
- [x] 4.3 Add validation for auth mode metadata (`none|basic|digest|unknown`) and credential reference linkage.

## 5. Dependency and Compatibility
- [x] 5.1 Document `goxis` compatibility findings for TinyGo/WASM.
- [x] 5.2 Reuse only TinyGo-safe logic from `goxis` (if any) with attribution; avoid ACAP/native wrappers.
- [x] 5.3 Evaluate whether a ServiceRadar `goxis` fork is needed; decision: not needed for this change because the in-tree `internal/axisref` extraction is sufficient and WASM-safe.
- [x] 5.4 Add CI checks/tests for the forked package to prevent accidental reintroduction of cgo/native dependencies.
- [x] 5.5 Define extraction manifest listing exact source files copied/adapted from `goxis` and their target package paths.
- [x] 5.6 Add compatibility tests that verify extracted helpers build under plugin TinyGo/WASM constraints.

## 6. Tests and Verification
- [x] 6.1 Add unit tests for VAPIX parsing and enrichment payload generation.
- [x] 6.2 Add ingestion tests for enrichment upsert and event promotion behavior.
- [x] 6.3 Add end-to-end plugin smoke test against an AXIS camera (or mocked VAPIX server) covering discovery, stream enrichment, and event emission.
- [x] 6.4 Run `openspec validate add-axis-vapix-wasm-plugin --strict`.
