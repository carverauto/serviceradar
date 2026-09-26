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

### Requirement: Analysis results carry multiple detections
The `camera_analysis_result.v1` contract SHALL accept a list of detections per analysed frame, each with a label, confidence, normalized bounding box and the frame's media timestamp, while continuing to accept the existing single `detection` field.

#### Scenario: Three objects in one frame
- **WHEN** a worker returns a result with three detections for one frame
- **THEN** the platform SHALL ingest all three with the frame's media timestamp and relay session provenance

#### Scenario: Legacy single detection
- **WHEN** an existing worker returns only the single `detection` field
- **THEN** the platform SHALL ingest it as a one-element detection list

### Requirement: Detections are delivered to active viewers
The platform SHALL deliver analysis detections for a relay session to that session's authorized viewers in real time, and SHALL drop detections older than the configured latency budget instead of delivering them late.

#### Scenario: Viewer receives detections
- **WHEN** an analysis branch produces detections for a relay session that a viewer is watching
- **THEN** the viewer SHALL receive them tagged with the media timestamp of their frame

#### Scenario: Late detection
- **WHEN** a detection arrives after the latency budget for its frame has elapsed
- **THEN** the platform SHALL NOT deliver it to viewers
- **AND** SHALL still ingest it as an event

### Requirement: Analysis runs a real inference worker
The platform SHALL support an HTTP analysis worker that performs object-detection inference with a packaged model, registered, probed and health-tracked through the existing analysis worker registry.

#### Scenario: Worker detects objects in replayed footage
- **GIVEN** the inference worker is registered and a relay session replays a clip containing vehicles
- **WHEN** the analysis branch samples frames
- **THEN** the worker SHALL return vehicle detections with bounding boxes and confidences derived from the frames
