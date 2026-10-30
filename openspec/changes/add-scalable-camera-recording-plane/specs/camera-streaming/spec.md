## MODIFIED Requirements

### Requirement: Relay sessions support analysis branches
The system SHALL allow analysis consumers to attach to an active camera relay session at its assigned core or recorder ingress without creating a second upstream ingest for the same camera stream profile.

#### Scenario: Analysis attaches to an already-active relay
- **GIVEN** a relay session is active for camera `cam-1` profile `high`
- **WHEN** an authorized analysis branch is started for that relay session
- **THEN** the platform SHALL attach the analysis branch to the existing relay ingest
- **AND** SHALL NOT instruct the agent to open a second camera source session

### Requirement: Relay sessions support WebRTC viewer egress
The system SHALL support a WebRTC viewer egress path for camera relay sessions from the assigned core or recorder relay, and that egress SHALL reuse the existing relay ingest for the same camera stream profile.

#### Scenario: Browser attaches using WebRTC
- **GIVEN** an active relay session for camera `cam-1` profile `high`
- **WHEN** an authorized browser requests WebRTC playback for that relay session
- **THEN** the platform SHALL establish a WebRTC viewer session bound to that relay session
- **AND** SHALL NOT create a second upstream camera ingest for the same camera/profile

### Requirement: Membrane relay fans out a single upstream session
The system SHALL use Membrane at the assigned core or recorder ingress to fan out one active upstream camera ingest to multiple authorized viewers of the same camera stream profile. Within a deployment, additional viewers MUST NOT create another camera source session or edge-to-cloud live media uplink for that profile, including across relay replicas. Each browser SHALL retain its own authorized downstream transport; shared upstream media is mandatory.

#### Scenario: Two viewers open the same camera profile
- **GIVEN** one operator already viewing camera `cam-1` profile `main`
- **WHEN** a second authorized operator opens the same camera/profile
- **THEN** the platform SHALL reuse the existing upstream ingest
- **AND** SHALL attach the second viewer to the relay session
- **AND** SHALL NOT instruct the agent to open a second source session to the camera
- **AND** SHALL NOT open an additional edge-to-cloud live media upload for the second viewer

#### Scenario: Concurrent viewers reach different relay replicas
- **GIVEN** no live viewer yet exists for an admitted camera/profile
- **WHEN** authorized viewers concurrently request it through different replicas
- **THEN** admission SHALL resolve one assignment-scoped source and live uplink owner
- **AND** Membrane SHALL fan out that shared ingest to the viewers
- **AND** unresolved ownership SHALL wait within a deadline or reject admission rather than create duplicate sources or live uploads

#### Scenario: A slow viewer disconnects and reconnects
- **GIVEN** multiple authorized viewers share one source and live uplink
- **WHEN** one viewer exhausts its bounded queue or reconnects
- **THEN** the platform SHALL isolate or disconnect that viewer without stalling recording or unrelated viewers
- **AND** reconnection SHALL attach to the existing owner without opening another camera source or live upload

### Requirement: Gateway/core relay forwarding preserves one internal session target
For each accepted camera relay session, the authenticated media bridge SHALL bind chunks, heartbeats and close to one assignment-scoped ingress target for that relay lifetime. The default gateway-to-core path SHALL remain supported; an admitted recorder assignment MAY instead target its authenticated recorder service. Customer-operated recorders SHALL not require membership in the cloud ERTS cluster.

#### Scenario: Session-scoped ingress target handles chunk flow
- **GIVEN** the platform has allocated a core or recorder ingress target for relay session `S`
- **WHEN** the media bridge forwards media chunks, heartbeats and close for `S`
- **THEN** those operations SHALL target the same session-scoped ingress target
- **AND** forwarding SHALL remain within the authorized deployment boundary using agent-owned session authentication
- **AND** recorder loss SHALL not silently redirect the session to another owner or storage lifetime

#### Scenario: Customer recorder receives a local uplink
- **GIVEN** a customer recorder is assigned the source/profile
- **WHEN** its enrolled agent opens that assignment's media bridge
- **THEN** the bridge SHALL use bounded authenticated local transport without sending recording bytes through the cloud hub
- **AND** source handoff SHALL require the assignment retirement and fencing contract before another target becomes active

### Requirement: Edge-routed camera media uplinks
The system SHALL establish camera ingest through agent-originated media uplinks to the assigned core or recorder relay. The default cloud route SHALL use `serviceradar-agent-gateway`; customer-local recording MAY use an explicitly admitted authenticated local bridge. Hosted viewing of customer-local media SHALL use agent-established outbound control and media paths. The system SHALL NOT require direct platform-to-camera or platform-to-customer-recorder reachability, inbound firewall access, VPN or customer cloud-BEAM membership for normal operation.

#### Scenario: Camera is reachable only from the customer network
- **GIVEN** a camera that is reachable from an enrolled ServiceRadar agent but not from the platform directly
- **WHEN** an operator requests a live view for that camera
- **THEN** the agent SHALL open the local camera source session or reuse the admitted recording source for that profile
- **AND** SHALL push the uplink through the assigned authenticated bridge, using `serviceradar-agent-gateway` for the default cloud route
- **AND** the platform SHALL create the viewer session without directly dialing the camera

#### Scenario: Local recording continues without a cloud viewer
- **GIVEN** a customer-local recorder assignment with valid authority
- **WHEN** no cloud viewer is connected
- **THEN** the source SHALL feed the local recorder without a cloud media round-trip
- **AND** a later authorized viewer SHALL consume the existing ingest rather than open another camera connection for that profile

#### Scenario: Hosted viewers attach behind an inbound-deny firewall
- **GIVEN** customer ingress is denied and an agent-established gateway control connection is available
- **WHEN** authorized hosted viewers request a customer-local camera/profile
- **THEN** the runtime SHALL send an attach command over the existing control path
- **AND** the agent SHALL initiate one shared bounded live upload from the assigned ingest through the gateway
- **AND** the public Membrane relay SHALL fan out to the authorized browsers without dialing the customer network

### Requirement: Viewer sessions are authorized and short-lived
The system SHALL require an authorized viewer session before exposing live camera media, and SHALL tear down the shared upstream ingest after the configured idle timeout only when no viewer, recorder or authorized analysis lease remains.

#### Scenario: Last viewer disconnects
- **GIVEN** an active relay with one viewer and no recorder or analysis lease
- **WHEN** that viewer disconnects
- **THEN** the relay SHALL become idle and close after the configured timeout unless a consumer attaches

#### Scenario: Recording outlives viewers
- **GIVEN** a recorder lease on the same camera/profile ingest
- **WHEN** the last viewer disconnects
- **THEN** recording SHALL continue without opening a second source session
- **AND** a later viewer SHALL attach to the existing ingest

#### Scenario: Last hosted viewer leaves a local recording
- **GIVEN** an admitted customer-local recording and one shared cloud live upload for hosted viewers
- **WHEN** the last hosted viewer leaves and no other admitted cloud consumer needs that upload
- **THEN** the runtime SHALL retire only that upload and its downstream viewing resources after bounded idle handling
- **AND** the local source and recording SHALL continue under their existing authority without a WAN media round-trip

#### Scenario: Cloud recording retains the shared upload
- **GIVEN** an admitted cloud recorder consumes the shared agent upload
- **WHEN** the last viewer disconnects
- **THEN** the recording consumer SHALL keep that upload active
- **AND** a later viewer SHALL attach downstream without another source or upload

#### Scenario: Attach races with idle retirement
- **WHEN** a consumer attach races with reservation of idle source close
- **THEN** both operations SHALL serialize on the same source/profile ownership boundary
- **AND** an attach committed before close SHALL retain the source
- **AND** an attach after close reservation SHALL wait within its deadline or fail until retirement/reconciliation permits activation
- **AND** a delayed close SHALL address only its captured lifetime

#### Scenario: Consumer overload is isolated
- **WHEN** recording or optional analysis exceeds its admitted budget
- **THEN** the system SHALL expose its gap or rejected work
- **AND** SHALL preserve unrelated live viewer sessions and bounded resource use
