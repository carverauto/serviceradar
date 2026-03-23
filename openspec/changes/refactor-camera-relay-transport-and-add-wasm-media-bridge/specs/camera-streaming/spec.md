## ADDED Requirements
### Requirement: Native and Wasm camera sources share one relay uploader
The agent SHALL use one shared camera relay uploader implementation for both native camera readers and Wasm streaming plugins.

#### Scenario: Native and Wasm sources use the same relay lifecycle
- **GIVEN** one relay session is sourced by a native RTSP reader
- **AND** another relay session is sourced by a Wasm streaming plugin
- **WHEN** each session opens, uploads media, heartbeats, drains, and closes
- **THEN** both sessions SHALL use the same uploader semantics for leases, backpressure, and drain handling

### Requirement: Wasm streaming plugins do not use plugin results for live media
When a Wasm plugin is the source of a live camera relay, live media transport SHALL use the dedicated media bridge and relay uploader rather than the plugin result ingestion path.

#### Scenario: Live media bypasses plugin result ingestion
- **GIVEN** a Wasm camera plugin is sourcing live media for a viewer session
- **WHEN** the plugin writes media for that relay
- **THEN** the media SHALL be sent through the dedicated camera relay bridge
- **AND** the plugin result pipeline SHALL not be used to carry the media bytes

### Requirement: Gateway/core relay forwarding preserves one internal session target
For each accepted camera relay session, `serviceradar-agent-gateway` SHALL forward media to one session-scoped ingress target in `serviceradar_core_elx` for the lifetime of that relay.

#### Scenario: Session-scoped ingress target handles chunk flow
- **GIVEN** `serviceradar_core_elx` has allocated an ingress target for relay session `S`
- **WHEN** `serviceradar-agent-gateway` forwards media chunks, heartbeats, and close for `S`
- **THEN** those operations SHALL target the same session-scoped ingress target
- **AND** forwarding SHALL remain inside the platform ERTS cluster
