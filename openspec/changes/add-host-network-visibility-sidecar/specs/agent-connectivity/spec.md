> **SUPERSEDED 2026-09-02 by `add-remote-pcapng-capture`.** These
> requirements were written against libpcap, which no shipped netprobe
> build contains (`rust/netprobe/Cargo.toml:67` gates `pcap` behind a
> cargo feature that `rust/netprobe/BUILD.bazel:11-15` never enables).
> The corrected, authoritative delta for this capability lives in
> `openspec/changes/add-remote-pcapng-capture/specs/`. Apply that
> capability from there when archiving this change; the text below is
> kept as the record of what was originally specified.

## ADDED Requirements

### Requirement: gRPC server-streaming RPC for remote capture sessions

Agents and `agent-gateway` SHALL expose a new **gRPC server-streaming
RPC** named `RemotePacketCapture` whose request carries
`StartRemoteCaptureSession` (session id, target interfaces, BPF
filter, snaplen, duration cap, byte cap) and whose server-streamed
response carries `PcapngBlock` frames plus interleaved
`SessionStateChanged` lifecycle events. The RPC MUST be multiplexed
onto the existing mTLS HTTP/2 connection that already carries the
control stream and command bus defined by the `Agent control stream`
and `Command bus for on-demand actions` requirements; it MUST NOT
open any new TCP, UDP, or QUIC port and MUST NOT establish a
separate TLS session.

#### Scenario: Capture stream multiplexes onto the existing mTLS HTTP/2 connection
- **WHEN** a `StartRemoteCaptureSession` is dispatched to an agent
- **THEN** the resulting gRPC server-streaming RPC rides the same
  HTTP/2 connection as the existing control stream and command bus
- **AND** no additional TCP, UDP, QUIC, or TLS session is
  established on either side

#### Scenario: Stop command propagates within 1 second
- **WHEN** the gateway cancels the gRPC stream for an active session
  (e.g. via gRPC client-cancel)
- **THEN** the agent forwards cancellation to `netprobe` within 1
  second
- **AND** the next `PcapngBlock` frame the gateway receives carries
  `final = true`

### Requirement: Agent backpressure on capture streams

Agents SHALL apply backpressure to the pcapng frame stream when the
gateway's outbound channel cannot accept frames at the sidecar's
emission rate, by stalling reads from the `netprobe` UDS so that
flow control propagates to the sidecar's pcap handle. Agents MUST
NOT silently drop pcapng frames in transit.

#### Scenario: Slow gateway stalls the sidecar capture
- **WHEN** the gateway's outbound channel cannot accept frames at
  the sidecar's emission rate for an extended period
- **THEN** the agent stops reading from the sidecar UDS until
  capacity returns
- **AND** the sidecar's pcap handle drops packets at the kernel
  layer (visible in
  `serviceradar_netprobe_packets_dropped_total`) rather than the
  agent silently losing forwarded frames

### Requirement: Active capture session surfaced in agent status

The agent SHALL include a representation of any active remote capture
session in its existing `StatusResponse` (and through it the agent
registry), reporting at minimum the `session_id`, `requested_by`,
`bytes_streamed`, and `expires_at`. The representation MUST NOT
include the BPF filter or other potentially sensitive request
parameters in this surface; those remain accessible via the
`agent_capture:audit_view`-gated session resource.

#### Scenario: Active session is visible without audit permission
- **WHEN** an operator with `agent:read` but without
  `agent_capture:audit_view` views the agent status
- **THEN** the response indicates that a capture session is active
  and reports `bytes_streamed` and `expires_at`
- **AND** the response does not contain the `bpf_filter`,
  `requested_by_user_id`, or other audit-only fields
