# axis-camera-plugin Specification

## Purpose
TBD - created by archiving change add-axis-vapix-wasm-plugin. Update Purpose after archive.
## Requirements
### Requirement: Axis TinyGo/WASM plugin package
The system SHALL provide an AXIS camera plugin package implemented in TinyGo under `go/cmd/wasm-plugins/axis` that runs in the existing ServiceRadar WASM runtime.

#### Scenario: Axis plugin package is buildable
- **GIVEN** the ServiceRadar repository checkout
- **WHEN** a developer builds the AXIS plugin package
- **THEN** the build produces a WASM artifact and manifest compatible with `serviceradar.plugin_result.v1`

### Requirement: VAPIX capability and inventory collection
The AXIS plugin SHALL interrogate VAPIX device/capability endpoints and report normalized camera inventory metadata.

#### Scenario: Device metadata retrieved successfully
- **GIVEN** valid AXIS credentials and reachable camera endpoint
- **WHEN** the plugin runs
- **THEN** it SHALL collect model, firmware, serial, and capability metadata
- **AND** include normalized values in plugin result details and enrichment payloads

### Requirement: Stream discovery and normalization
The AXIS plugin SHALL discover camera streams from VAPIX APIs and emit normalized stream metadata including protocol and authentication requirements.

#### Scenario: RTSP profiles discovered
- **GIVEN** an AXIS camera exposing stream profiles
- **WHEN** the plugin executes stream discovery
- **THEN** the result SHALL include one or more stream entries with profile identifiers, endpoint metadata, and auth mode

### Requirement: Axis event extraction
The AXIS plugin SHALL collect AXIS camera events and map them to OCSF Event Log Activity records for downstream ingestion.

#### Scenario: Event mapped to OCSF
- **GIVEN** an AXIS camera event notification from the configured event source
- **WHEN** the plugin processes the notification
- **THEN** it SHALL emit a mapped OCSF event with timestamp, severity, and message fields

### Requirement: Graceful degradation across endpoint variability
The AXIS plugin SHALL continue partial collection when some VAPIX endpoints are unavailable on a camera model/firmware.

#### Scenario: Missing endpoint does not fail entire run
- **GIVEN** a camera firmware that does not expose one optional endpoint
- **WHEN** the plugin runs
- **THEN** the plugin SHALL report partial success with explicit missing-capability notes
- **AND** still submit available metrics and metadata

