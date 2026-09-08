## ADDED Requirements
### Requirement: Relay sessions support WebRTC viewer egress
The system SHALL support a WebRTC viewer egress path for camera relay sessions from `serviceradar_core_elx`, and that egress SHALL reuse the existing relay ingest for the same camera stream profile.

#### Scenario: Browser attaches using WebRTC
- **GIVEN** an active relay session for camera `cam-1` profile `high`
- **WHEN** an authorized browser requests WebRTC playback for that relay session
- **THEN** the platform SHALL establish a WebRTC viewer session bound to that relay session
- **AND** SHALL NOT create a second upstream camera ingest for the same camera/profile

### Requirement: WebRTC signaling remains relay-session-scoped
The system SHALL bind WebRTC viewer negotiation to the existing relay session model so authorization, viewer count, idle close, and terminal state reporting remain consistent across playback transports.

#### Scenario: Viewer negotiation uses the existing relay session
- **GIVEN** a relay session in `active` state
- **WHEN** a browser starts WebRTC negotiation
- **THEN** the signaling request SHALL reference the existing relay session identifier
- **AND** resulting viewer lifecycle updates SHALL affect the same persisted relay session

### Requirement: Websocket viewer path remains available during rollout
The system SHALL keep the current websocket camera viewer path available as a fallback while WebRTC viewer egress is being rolled out.

#### Scenario: WebRTC path is unavailable but fallback exists
- **GIVEN** a relay session that advertises both WebRTC and websocket playback transports
- **AND** WebRTC negotiation cannot be completed for the current viewer
- **WHEN** the viewer initializes
- **THEN** the system MAY fall back to the websocket playback path
- **AND** SHALL keep the viewer bound to the same relay session
