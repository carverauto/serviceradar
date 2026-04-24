## ADDED Requirements
### Requirement: Streaming plugins use a distinct long-lived runtime mode
The agent SHALL support a distinct streaming plugin mode for Wasm plugins that need to maintain a live media session. This mode SHALL be separate from the bounded execution path used for scheduled plugins that emit `serviceradar.plugin_result.v1`.

#### Scenario: Streaming plugin runs without using the one-shot result runtime
- **GIVEN** a Wasm plugin assignment with streaming media capability
- **WHEN** the agent starts the plugin for a camera relay session
- **THEN** the plugin SHALL run in the streaming plugin mode
- **AND** the agent SHALL NOT require the plugin to terminate immediately after emitting a `plugin_result`

### Requirement: Streaming plugins use a host media bridge
Streaming plugins SHALL access live camera media transport through dedicated host functions for media session open, chunk write, heartbeat, and close. The agent SHALL enforce capability and permission checks on those calls.

#### Scenario: Streaming plugin writes media through host functions
- **GIVEN** a streaming plugin has been granted camera media capability
- **WHEN** the plugin opens a relay session and writes encoded media chunks
- **THEN** it SHALL do so through the host media bridge
- **AND** the agent SHALL reject media bridge calls from plugins without the required capability

## MODIFIED Requirements
### Requirement: Standardized Plugin Results
Plugins MUST report results using the `serviceradar.plugin_result.v1` schema, and the agent MUST map those results into `GatewayServiceStatus`.

Plugin results MAY include optional enrichment and event blocks. Camera-capable plugins MAY also publish camera source and stream descriptors for downstream inventory/relay use. Plugin results MUST NOT carry continuous live media payloads. Streaming plugins SHALL use the host media bridge for live media instead of `submit_result`.

#### Scenario: Camera discovery plugin publishes descriptors
- **GIVEN** a camera plugin result containing source identifiers, stream descriptors, and status
- **WHEN** the payload is ingested
- **THEN** service status ingestion SHALL still preserve the plugin status
- **AND** the camera descriptors SHALL be routed into camera inventory processing
- **AND** no live media bytes SHALL be expected in the plugin result payload

#### Scenario: Streaming plugin sends media out-of-band
- **GIVEN** a streaming plugin is producing live encoded media for a relay session
- **WHEN** the plugin is running
- **THEN** live media SHALL flow through the host media bridge
- **AND** the plugin result pipeline SHALL remain limited to metadata, events, and status
