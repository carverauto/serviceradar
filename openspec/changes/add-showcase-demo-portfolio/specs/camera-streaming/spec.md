## ADDED Requirements

### Requirement: Relay viewer sessions serve dashboard packages
The system SHALL allow viewer sessions opened through the dashboard host camera API to use the same relay-session and WebRTC signaling endpoints, authorization and idle teardown as the web-ng camera pages.

#### Scenario: Dashboard and camera page view the same camera
- **WHEN** a dashboard tile and the `/cameras` page view the same camera stream profile
- **THEN** both SHALL attach to one relay ingest
- **AND** the agent SHALL NOT open a second upstream session

### Requirement: Browser media policy permits relay playback
The web application's content security policy SHALL permit exactly the media sources the relay player needs (`blob:` and `mediastream:`) and SHALL NOT permit arbitrary media origins.

#### Scenario: Fallback player in a dashboard
- **WHEN** WebRTC is unavailable and the player falls back to the websocket transport inside a dashboard
- **THEN** the browser SHALL be allowed to play the resulting blob media

### Requirement: WebRTC viewer egress is configurable per deployment
WebRTC viewer egress and its ICE/TURN servers SHALL be configurable through deployment configuration (Helm values and runtime configuration) rather than only through test configuration.

#### Scenario: Demo enables WebRTC
- **WHEN** the `demo` deployment sets the WebRTC enable flag and ICE servers in its values
- **THEN** viewer sessions in `demo` SHALL negotiate WebRTC using those ICE servers
