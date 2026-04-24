## MODIFIED Requirements
### Requirement: Streaming Plugin Host Bridge
The Wasm streaming plugin system SHALL let streaming plugins acquire vendor media sources through the shared host/runtime transport layer while continuing to use the existing `camera_media_open`, `camera_media_write`, `camera_media_heartbeat`, and `camera_media_close` bridge for relay session upload.

#### Scenario: Plaintext RTSP source for streaming plugin
- **WHEN** a streaming plugin opens a resolved `rtsp://...` source
- **THEN** the plugin uses the shared transport/runtime path and the existing camera media bridge without any change to the relay protocol

#### Scenario: TLS-protected RTSP source for streaming plugin
- **WHEN** a streaming plugin opens a resolved `rtsps://...` source
- **THEN** the plugin uses the shared transport/runtime path and the existing camera media bridge without requiring a second media bridge contract
