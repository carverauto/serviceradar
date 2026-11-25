## ADDED Requirements

### Requirement: Relay sessions record their origin
Each relay session SHALL record its origin as `agent_pull`, `push_orchestrated` or `source_initiated`. The relay SHALL open, activate and tear down each session according to that origin, while every origin feeds the same relay pipeline seam.

#### Scenario: Existing pull sessions are unchanged
- **WHEN** a viewer opens a camera whose source is agent-pulled
- **THEN** Core SHALL dispatch `camera.open_relay` to the assigned agent exactly as before

### Requirement: Push-orchestrated relay sessions
For a push-ingest camera source, Core SHALL reserve the relay session, mint a session-scoped ingest token stored only as a hash, and request the device's push through the source's controlling gateway instead of dispatching to an agent. The ingest SHALL attach a publisher only when it presents that token while the session is reserved and has no active publisher. After a publisher-loss grace window, Core SHALL re-mint the token and re-request the push if any lease remains.

#### Scenario: Viewer starts a drone live view
- **WHEN** an authorized viewer opens a DJI camera stream profile
- **THEN** Core SHALL reserve a session and ask the DJI gateway to start a push, choosing the protocol from the device's reported capability and the enabled ingests
- **AND** the session SHALL become active when the device's push presents the session token

#### Scenario: Token reuse is refused
- **WHEN** a publisher presents a token for a session that has ended, that has an active publisher, or that Core has since re-minted
- **THEN** the ingest SHALL refuse the connection

#### Scenario: Publisher reconnects within grace
- **WHEN** a pushing device's connection drops and the device reconnects with the same token within the publisher-loss grace window
- **THEN** the ingest SHALL re-attach it to the same session
- **AND** viewers and the recorder SHALL resume without Core re-requesting the push

#### Scenario: Publisher does not return
- **WHEN** the publisher-loss grace window expires and a viewer or recorder lease remains
- **THEN** Core SHALL mint a new token and ask the gateway to restart the push

#### Scenario: Idle teardown stops the push
- **WHEN** the last viewer leaves and no recorder or analysis lease holds the session
- **THEN** the relay SHALL tear the session down and ask the gateway to stop the device's push

### Requirement: Source-initiated relay sessions
The relay SHALL accept pushes from publishers presenting a long-lived, rotatable stream key bound to a camera source. It SHALL open or activate that source's session when the publisher connects and end it when the publisher disconnects. A source with no publisher SHALL show as offline rather than failed.

#### Scenario: Pilot manual livestream
- **WHEN** an operator configures DJI Pilot manual livestream with the source's published RTMP endpoint and key, then starts streaming
- **THEN** the source's session SHALL become active and viewable without any viewer having requested it first

#### Scenario: Rotated key
- **WHEN** an operator rotates a source's stream key
- **THEN** pushes using the previous key SHALL be refused

### Requirement: RTMP and WHIP ingest normalize to the relay chunk contract
The RTMP ingest and the WHIP ingest SHALL deliver H.264 Annex-B access units with 90 kHz timestamps to the relay pipeline. The RTMP ingest SHALL demux H.265 delivered over enhanced RTMP. Until the media pipeline supports H.265 end to end, the ingest SHALL transcode H.265 to H.264 within per-session bounds.

#### Scenario: H.265 push
- **WHEN** a device pushes H.265 over enhanced RTMP
- **THEN** viewers, recording and analysis SHALL receive H.264 from the relay
- **AND** the transcode SHALL be visible in relay metrics

#### Scenario: Reordered frames
- **WHEN** a pushed H.264 stream contains reordered frames
- **THEN** the stream profile SHALL be marked not recordable with a visible reason
- **AND** live viewing SHALL continue

#### Scenario: DJI onboard detections over WHIP
- **WHEN** a dock publishing over WHIP embeds onboard AI detection SEI in the video
- **THEN** the ingest SHALL extract the detections as camera observations for that camera source
