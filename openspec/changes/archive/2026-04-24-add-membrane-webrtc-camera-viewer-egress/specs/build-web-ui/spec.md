## ADDED Requirements
### Requirement: Camera viewers prefer WebRTC when advertised
The UI SHALL prefer WebRTC playback for camera relay sessions when the relay advertises a WebRTC transport and the browser can use it.

#### Scenario: Browser uses WebRTC on the device page
- **GIVEN** a device detail page with an active camera relay session
- **AND** the relay session advertises WebRTC playback
- **WHEN** the browser supports the advertised WebRTC path
- **THEN** the viewer SHALL initialize using WebRTC

#### Scenario: Browser uses WebRTC in God-View
- **GIVEN** God-View opens one or more active camera relay viewers
- **AND** those relay sessions advertise WebRTC playback
- **WHEN** the browser supports the advertised WebRTC path
- **THEN** each viewer SHALL prefer WebRTC playback

### Requirement: Camera viewers surface fallback and negotiation state
The UI SHALL make WebRTC negotiation and fallback behavior explicit so operators can distinguish successful WebRTC playback, fallback to websocket playback, and viewer initialization failures.

#### Scenario: Viewer falls back from WebRTC to websocket
- **GIVEN** a relay session advertises both WebRTC and websocket playback
- **AND** WebRTC negotiation fails for the current browser or network path
- **WHEN** the viewer falls back to websocket playback
- **THEN** the UI SHALL indicate that fallback occurred
- **AND** SHALL continue to display relay session state and termination details

#### Scenario: No viewer transport can be established
- **GIVEN** a relay session is active
- **AND** neither WebRTC nor websocket playback can be established
- **WHEN** the viewer initializes
- **THEN** the UI SHALL show an explicit failure state
- **AND** SHALL NOT render an ambiguous blank viewer surface
