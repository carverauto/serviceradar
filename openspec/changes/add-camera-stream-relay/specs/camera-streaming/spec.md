## ADDED Requirements
### Requirement: Edge-routed camera media uplinks
The system SHALL establish live camera viewing through agent-originated media uplinks routed via `serviceradar-agent-gateway` to a relay in `serviceradar_core_elx`. The system SHALL NOT require direct platform-to-camera reachability for normal operation.

#### Scenario: Camera is reachable only from the customer network
- **GIVEN** a camera that is reachable from an enrolled ServiceRadar agent but not from the platform directly
- **WHEN** an operator requests a live view for that camera
- **THEN** the agent SHALL open the local camera source session
- **AND** SHALL push the media uplink through `serviceradar-agent-gateway`
- **AND** the platform SHALL create the viewer session without directly dialing the camera

### Requirement: Membrane relay fans out a single upstream session
The system SHALL use Membrane in `serviceradar_core_elx` to fan out one active upstream camera ingest to multiple authorized viewers of the same camera stream profile.

#### Scenario: Two viewers open the same camera profile
- **GIVEN** one operator already viewing camera `cam-1` profile `main`
- **WHEN** a second authorized operator opens the same camera/profile
- **THEN** the platform SHALL reuse the existing upstream ingest
- **AND** SHALL attach the second viewer to the relay session
- **AND** SHALL NOT instruct the agent to open a second source session to the camera

### Requirement: Viewer sessions are authorized and short-lived
The system SHALL require an authorized viewer session before exposing live camera media, and relay sessions SHALL be torn down when no viewers remain after the configured idle timeout.

#### Scenario: Last viewer disconnects
- **GIVEN** an active relay session with one remaining viewer
- **WHEN** that viewer disconnects
- **THEN** the system SHALL mark the relay session idle
- **AND** SHALL tear down the upstream ingest after the configured idle timeout unless a new viewer joins first

### Requirement: Camera availability and relay state are visible
The system SHALL expose camera stream availability and relay state so operators can distinguish unreachable cameras, auth failures, unsupported codecs, and healthy live streams.

#### Scenario: Camera source cannot be opened by the agent
- **GIVEN** a camera stream profile exists for a device
- **AND** the assigned agent cannot open the local source session
- **WHEN** the operator requests live view
- **THEN** the relay session SHALL transition to an error state
- **AND** the operator-facing response SHALL identify that the stream is unavailable rather than silently showing no video

### Requirement: Relay sessions expose normalized terminal outcomes
The system SHALL expose a normalized relay termination classification with relay session reads and browser-facing relay state snapshots so clients can distinguish manual stop, viewer-idle teardown, transport drain, source completion, and failure without parsing freeform reason strings.

#### Scenario: Viewer idle teardown is reported to the browser
- **GIVEN** a relay session that entered closing because the last viewer left
- **WHEN** the terminal relay session snapshot is published
- **THEN** the snapshot SHALL include `termination_kind = "viewer_idle"`
- **AND** MAY also include the raw `close_reason`

#### Scenario: Manual stop is reported separately from transport drain
- **GIVEN** an operator explicitly stops a relay session
- **AND** the upstream media path later drains and acknowledges shutdown
- **WHEN** the relay session is read by API or browser consumers
- **THEN** the session SHALL preserve the user-facing shutdown classification
- **AND** SHALL NOT replace it with a transport-only terminal classification
