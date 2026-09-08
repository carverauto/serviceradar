# camera-streaming Specification

## Purpose
TBD - created by archiving change add-camera-stream-analysis-egress. Update Purpose after archive.
## Requirements
### Requirement: Relay sessions support analysis branches
The system SHALL allow analysis consumers to attach to an active camera relay session in `serviceradar_core_elx` without creating a second upstream ingest for the same camera stream profile.

#### Scenario: Analysis attaches to an already-active relay
- **GIVEN** a relay session is active for camera `cam-1` profile `high`
- **WHEN** an authorized analysis branch is started for that relay session
- **THEN** the platform SHALL attach the analysis branch to the existing relay ingest
- **AND** SHALL NOT instruct the agent to open a second camera source session

### Requirement: Analysis extraction is bounded
The system SHALL support bounded extraction policies for analysis work so processing taps can sample or transform media without unbounded resource consumption.

#### Scenario: Analysis uses sampled frames
- **GIVEN** an analysis branch is configured to extract one frame every two seconds
- **WHEN** the relay session remains active
- **THEN** the platform SHALL emit analysis inputs at that bounded rate
- **AND** SHALL NOT forward every frame when the extraction policy does not require it

### Requirement: Analysis branches may dispatch to external HTTP workers
The system SHALL allow a relay-scoped analysis branch to dispatch bounded `camera_analysis_input.v1` payloads to configured external HTTP workers without creating another upstream camera pull.

#### Scenario: Relay sample is delivered to a worker
- **GIVEN** an active relay session with an attached analysis branch
- **AND** an HTTP worker is configured for that branch
- **WHEN** the branch emits a bounded analysis input
- **THEN** the platform SHALL dispatch the normalized input payload to the worker
- **AND** SHALL keep the dispatch associated with the originating relay session and branch identity

### Requirement: Analysis dispatch must remain bounded
The system SHALL bound analysis worker dispatch so relay playback and ingest remain prioritized over analysis delivery.

#### Scenario: Worker pressure exceeds dispatch limits
- **GIVEN** an active relay session with an attached analysis branch
- **AND** the configured worker is slower than the sample rate
- **WHEN** dispatch concurrency or timeout limits are exceeded
- **THEN** the platform SHALL drop or reject excess analysis work
- **AND** SHALL NOT block viewer playback or require another upstream camera pull

### Requirement: Native and Wasm camera sources share one relay uploader
The agent SHALL use one shared camera relay uploader implementation for both native camera readers and Wasm streaming plugins.

#### Scenario: Native and Wasm sources use the same relay lifecycle
- **GIVEN** one relay session is sourced by a native RTSP reader
- **AND** another relay session is sourced by a Wasm streaming plugin
- **WHEN** each session opens, uploads media, heartbeats, drains, and closes
- **THEN** both sessions SHALL use the same uploader semantics for leases, backpressure, and drain handling

### Requirement: Wasm streaming plugins do not use plugin results for live media
When a Wasm plugin is the source of a live camera relay, live media transport SHALL use the dedicated media bridge and relay uploader rather than the plugin result ingestion path.

#### Scenario: Live media bypasses plugin result ingestion
- **GIVEN** a Wasm camera plugin is sourcing live media for a viewer session
- **WHEN** the plugin writes media for that relay
- **THEN** the media SHALL be sent through the dedicated camera relay bridge
- **AND** the plugin result pipeline SHALL not be used to carry the media bytes

### Requirement: Gateway/core relay forwarding preserves one internal session target
For each accepted camera relay session, `serviceradar-agent-gateway` SHALL forward media to one session-scoped ingress target in `serviceradar_core_elx` for the lifetime of that relay.

#### Scenario: Session-scoped ingress target handles chunk flow
- **GIVEN** `serviceradar_core_elx` has allocated an ingress target for relay session `S`
- **WHEN** `serviceradar-agent-gateway` forwards media chunks, heartbeats, and close for `S`
- **THEN** those operations SHALL target the same session-scoped ingress target
- **AND** forwarding SHALL remain inside the platform ERTS cluster

### Requirement: Relay session mutations remain agent-owned
The gateway SHALL bind relay session heartbeat, media upload, and close operations to the authenticated agent identity that opened the relay session. Session reference values such as `relay_session_id` and `media_ingest_id` SHALL NOT be sufficient by themselves to authorize relay mutation.

#### Scenario: Session owner mutates relay successfully
- **GIVEN** agent `A` opened relay session `S`
- **AND** the gateway recorded `A` as the owner of `S`
- **WHEN** agent `A` sends a valid media chunk, heartbeat, or close request for `S`
- **THEN** the gateway accepts the request

#### Scenario: Different agent is denied relay mutation
- **GIVEN** agent `A` opened relay session `S`
- **AND** agent `B` learns `S`'s `relay_session_id` and `media_ingest_id`
- **WHEN** agent `B` sends a media chunk, heartbeat, or close request for `S`
- **THEN** the gateway rejects the request
- **AND** the relay session remains bound to agent `A`

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

