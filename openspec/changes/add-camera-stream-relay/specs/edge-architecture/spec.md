## ADDED Requirements
### Requirement: Edge camera media flows are agent-initiated
Live camera media flows SHALL be initiated from the edge agent toward `serviceradar-agent-gateway` and the platform. The platform SHALL NOT depend on inbound connectivity from the customer network or direct camera reachability for live viewing.

#### Scenario: Platform cannot route directly to the camera
- **GIVEN** a customer camera is behind private addressing or NAT
- **WHEN** an operator starts a live view session
- **THEN** the platform SHALL request the assigned agent to start the camera source session
- **AND** the agent SHALL initiate the media uplink toward the platform
- **AND** live viewing SHALL NOT require opening a platform-to-camera connection

### Requirement: Agent-gateway forwards camera media under edge identity
`serviceradar-agent-gateway` SHALL authenticate the edge agent for camera media sessions and forward those sessions only within the authenticated deployment scope.

#### Scenario: Authenticated camera media uplink
- **GIVEN** an enrolled agent starts a camera media session
- **WHEN** the uplink reaches `serviceradar-agent-gateway`
- **THEN** the gateway SHALL bind the session to the authenticated agent identity
- **AND** SHALL forward the session to the platform relay
- **AND** SHALL reject media uplinks from unauthenticated edge identities

### Requirement: Camera media transport is separate from monitoring status services
The system SHALL use a dedicated camera media service for live-view control and media uplink rather than carrying live camera transport over the generic monitoring status/results service.

#### Scenario: Live camera session starts
- **GIVEN** an operator requests a live camera session
- **WHEN** the platform coordinates the edge uplink
- **THEN** the agent, gateway, and platform SHALL use the camera media service for relay control and media transport
- **AND** the generic monitoring status/results service SHALL remain unchanged for health and plugin payload ingestion
