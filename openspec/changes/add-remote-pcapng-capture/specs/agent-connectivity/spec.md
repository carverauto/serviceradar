## ADDED Requirements

### Requirement: gRPC bidirectional streaming RPC for remote capture sessions

The agent to agent-gateway protocol SHALL carry a
`RemotePacketCaptureService` with a single **bidirectional-streaming** RPC
`StreamCapture(stream RemotePacketCaptureClientMessage) returns (stream
RemotePacketCaptureServerMessage)`. The client message is a oneof of
`StartRemoteCaptureSession`, `CaptureBlock` and `SessionStateChanged`; the
server message is a oneof of `CaptureAck` and `CaptureCancel`. The RPC MUST
multiplex onto the existing mTLS HTTP/2 connection between the agent and
its gateway and MUST NOT open a second TCP or TLS session.

The first client message on the stream MUST be `StartRemoteCaptureSession`,
and a server that receives any other message first MUST close the stream.

Flow control SHALL be credit-based: the agent MUST NOT send more bytes than
the credit it has been granted. Credit exists because the agent cannot slow a
capture at its source -- the kernel's ring fills at line rate whatever
userspace does -- so the only honest response to a slow consumer is to stop
reading and let `netprobe` REPORT the resulting drops. Buffering without bound
in the agent would convert a reported drop count into an unreported one.

**CORRECTED before implementing.** This requirement originally specified a
*server-streaming* RPC, `Stream(StartRemoteCaptureSession) returns (stream
RemotePacketCaptureFrame)`. That points the data the wrong way. The gateway is
the gRPC **server** and the agent is the client -- "communication flows UP only
(agent to gateway); the gateway never connects back to agents" is stated as
invariant in the gateway's own architecture notes, and it is what lets an agent
sit behind a firewall with no inbound rules. A server-streaming RPC has the
SERVER produce the stream, so as written it had the gateway streaming pcapng to
the agent, away from the host the packets are on.

Client-streaming would carry the bytes the right way and still be wrong: it
gives the server no channel to speak on until the client is finished, so it
cannot satisfy this requirement's own cancellation scenario below. A capture on
a silent interface can run to its duration cap without sending a single message,
and that is precisely the session an operator is most likely to want to stop, so
cancellation cannot ride on the acknowledgement of data that may never come.

The narrative moved below the normative text rather than above it because
`openspec validate --strict` reads a requirement's FIRST line as its statement:
with the correction leading, this requirement parsed as prose and was reported
as containing no SHALL or MUST at all.

#### Scenario: Capture stream reuses the existing connection
- **WHEN** a capture session is dispatched to an agent that already holds
  a control-stream connection to its gateway
- **THEN** the capture stream is carried on that same connection
- **AND** no additional TCP or TLS session is established for it

#### Scenario: Cancellation propagates to the sidecar
- **WHEN** the gateway sends a `CaptureCancel` on the downstream channel
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
