## ADDED Requirements
### Requirement: Browser camera egress stays platform-local
The system SHALL deliver WebRTC camera playback from platform-local services, and browsers SHALL NOT negotiate media sessions directly with edge agents or customer cameras.

#### Scenario: Browser opens a live camera view
- **GIVEN** an operator opens a live camera view in the browser
- **WHEN** the viewer requests WebRTC playback
- **THEN** the browser SHALL negotiate the session against platform-local signaling/media endpoints
- **AND** SHALL NOT contact the agent or camera directly

### Requirement: WebRTC viewer egress does not change edge uplink transport
The system SHALL keep the existing agent-originated media uplink architecture when adding WebRTC browser egress.

#### Scenario: WebRTC viewer attaches to an existing relay
- **GIVEN** an agent-originated camera uplink is already active for a relay session
- **WHEN** a browser viewer attaches using WebRTC
- **THEN** the agent-to-gateway and gateway-to-core ingest path SHALL remain unchanged
- **AND** only the browser-facing egress path SHALL differ
