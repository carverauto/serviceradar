## ADDED Requirements

### Requirement: Camera relay WebRTC viewers receive per-viewer ICE credentials
The system SHALL give each camera relay WebRTC viewer session the ICE servers minted for it by the shared ICE credential provider.
The core-elx ExWebRTC peer for that relay SHALL use its own server-side minted credentials, so relay candidates are available on both sides.

#### Scenario: Viewer behind a symmetric NAT connects through the relay
- **GIVEN** an active relay session and a deployment with a credential backend other than `none`
- **AND** a browser viewer whose network blocks every host and server-reflexive candidate pair
- **WHEN** the viewer negotiates WebRTC for that relay session
- **THEN** ICE SHALL complete over a relay candidate
- **AND** the viewer SHALL stay bound to the same relay session

#### Scenario: Credentials unavailable
- **GIVEN** the credential provider returns status `unavailable`
- **WHEN** a viewer negotiates WebRTC
- **THEN** the viewer SHALL receive the STUN-only ICE list
- **AND** SHALL remain eligible for the websocket playback fallback
