## MODIFIED Requirements
### Requirement: Edge Camera Stream Sources
The system SHALL support camera relay sources discovered through vendor plugins, including sources expressed as `rtsp://` and `rtsps://` URLs, when those sources are selected for a relay session.

#### Scenario: Relay source uses plaintext RTSP
- **WHEN** a vendor plugin resolves a camera stream as `rtsp://...`
- **THEN** the streaming path opens the source and relays media through the existing camera media bridge

#### Scenario: Relay source uses RTSP over TLS
- **WHEN** a vendor plugin resolves a camera stream as `rtsps://...`
- **THEN** the streaming path opens the TLS-protected source and relays media through the existing camera media bridge

#### Scenario: Unsupported secure source handling
- **WHEN** the runtime cannot satisfy the requirements of a resolved `rtsps://...` source
- **THEN** the relay attempt fails with an explicit transport error instead of silently falling back to the wrong source
