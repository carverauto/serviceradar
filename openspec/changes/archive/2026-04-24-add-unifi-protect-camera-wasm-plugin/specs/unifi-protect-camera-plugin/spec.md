# unifi-protect-camera-plugin Specification

## ADDED Requirements
### Requirement: UniFi Protect TinyGo/WASM plugin package
The system SHALL provide a UniFi Protect camera plugin package implemented in TinyGo under `go/cmd/wasm-plugins/unifi-protect` that runs in the existing ServiceRadar WASM runtime.

#### Scenario: Protect plugin package is buildable
- **GIVEN** the ServiceRadar repository checkout
- **WHEN** a developer builds the UniFi Protect plugin package
- **THEN** the build SHALL produce a WASM artifact and manifest compatible with the existing plugin runtime

### Requirement: Protect camera inventory and stream discovery
The UniFi Protect plugin SHALL interrogate Protect controller APIs and report normalized camera inventory metadata and stream descriptors.

#### Scenario: Protect camera metadata retrieved successfully
- **GIVEN** valid Protect controller credentials and reachable controller APIs
- **WHEN** the plugin runs
- **THEN** it SHALL collect camera identity metadata and stream descriptor information
- **AND** include normalized values in plugin result details and enrichment payloads

### Requirement: Protect event extraction
The UniFi Protect plugin SHALL collect relevant Protect camera events and map them to OCSF-compatible event payloads for downstream ingestion.

#### Scenario: Protect event mapped for ingestion
- **GIVEN** a UniFi Protect event notification from the configured controller
- **WHEN** the plugin processes the notification
- **THEN** it SHALL emit a mapped event payload with normalized timestamp, severity, and message fields

### Requirement: Protect live media bridge path
The UniFi Protect plugin SHALL provide a `stream_camera` entrypoint that uses the existing Wasm camera media bridge and shared SDK transport helpers.

#### Scenario: Protect stream entrypoint uses existing relay bridge
- **GIVEN** an assigned Protect camera streaming plugin and an active relay session
- **WHEN** the plugin starts live media sourcing
- **THEN** it SHALL source media through the existing `camera_media_stream` bridge path
- **AND** SHALL NOT require new host functions or a new internal transport
