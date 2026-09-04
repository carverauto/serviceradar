## ADDED Requirements

### Requirement: gRPC server-streaming RPC for remote capture sessions

The agent to agent-gateway protocol SHALL carry a `RemotePacketCapture`
service with a single server-streaming RPC `Stream(StartRemoteCaptureSession)
returns (stream RemotePacketCaptureFrame)`, where `RemotePacketCaptureFrame`
is a oneof of `PcapngBlock` and `SessionStateChanged`. The RPC MUST
multiplex onto the existing mTLS HTTP/2 connection between the agent and
its gateway and MUST NOT open a second TCP or TLS session.

#### Scenario: Capture stream reuses the existing connection
- **WHEN** a capture session is dispatched to an agent that already holds
  a control-stream connection to its gateway
- **THEN** the capture stream is carried on that same connection
- **AND** no additional TCP or TLS session is established for it

#### Scenario: Cancellation propagates to the sidecar
- **WHEN** the gateway cancels the capture stream
- **THEN** the agent propagates the cancellation to `netprobe` within
  1 second
- **AND** the next frame the gateway receives carries the terminal
  session state

### Requirement: Session byte accounting without parsing pcapng

The agent SHALL count bytes per capture session and emit a
`SessionStateChanged` frame at 1 Hz so the gateway and
`serviceradar-core` can track `bytes_streamed` without decoding pcapng.
Byte accounting MUST NOT require any hop to parse or re-encode block
bytes.

#### Scenario: Byte counts arrive without block parsing
- **WHEN** a capture session streams for 5 seconds
- **THEN** the gateway receives approximately 5 `SessionStateChanged`
  frames carrying a monotonically non-decreasing `bytes_streamed`
- **AND** no hop between the sidecar and the client has parsed a pcapng
  block

### Requirement: Active capture session surfaced in agent status

An agent with a capture session in progress SHALL report that state in
its status response and on its agent-registry record, so operators and
dashboards can identify busy agents without polling agents directly. The
agent capability vocabulary SHALL carry `remote-packet-capture`,
advertised as `enabled` where the feature is available and `unavailable`
otherwise.

#### Scenario: Busy agent is visible without polling
- **WHEN** an agent is streaming a capture session
- **THEN** its status response reports an active capture session
- **AND** its agent-registry record reflects the same state
