> **SUPERSEDED 2026-09-02 by `add-remote-pcapng-capture`.** These
> requirements were written against libpcap, which no shipped netprobe
> build contains (`rust/netprobe/Cargo.toml:67` gates `pcap` behind a
> cargo feature that `rust/netprobe/BUILD.bazel:11-15` never enables).
> The corrected, authoritative delta for this capability lives in
> `openspec/changes/add-remote-pcapng-capture/specs/`. Apply that
> capability from there when archiving this change; the text below is
> kept as the record of what was originally specified.

## ADDED Requirements

### Requirement: Remote Packet Capture Session Resource

`serviceradar-core` SHALL persist remote capture sessions as
`Serviceradar.Telemetry.RemotePacketCaptureSession` Ash records. Each
record MUST carry `session_id` (ULID), `partition_id`, `agent_id`,
`target_interfaces`, `bpf_filter`, `snaplen`, `duration_s`,
`byte_cap`, `requested_by_user_id`, `requested_at`, `state` (one of
`requested`, `authorised`, `active`, `completed`, `aborted`,
`timed_out`, `denied`), `bytes_streamed`, and `last_block_at`.
Sessions MUST be partition-scoped via `Ash.Policy.Authorizer` such
that a user holding the requesting permission in one tenant cannot
target an agent in another tenant. The resource MUST enable
AshPaperTrail (or the project's owned AshPaperTrail wrapper if one is
standardized before Phase 5) so every create, update, and terminal
state transition has a durable version record.

#### Scenario: Cross-tenant session is denied
- **WHEN** a user with `agent_capture:remote` in tenant A submits a
  capture request naming an agent that belongs to tenant B
- **THEN** the request is denied
- **AND** no `RemotePacketCaptureSession` record is created in either
  tenant
- **AND** an audit record indicating the denial is written

#### Scenario: Every state transition is audit-logged
- **WHEN** a session moves from any state to any other state
- **THEN** AshPaperTrail records a version carrying the prior state,
  new state, transition reason, actor, partition, request id, target
  agent id, target interface list, BPF filter metadata, and bytes
  streamed at the time of transition
- **AND** the standard audit feed can render the same transition from
  the AshPaperTrail-backed record

### Requirement: Invasive Operator Action Audit Trail

The system SHALL audit any operator-initiated action that starts,
authorizes, stops, or materially expands packet observation. When the
action changes an Ash resource, the audit source of truth MUST be
AshPaperTrail. This includes remote packet capture sessions and
operator-managed capture posture records such as capture-interface
allowlists and visibility profiles when those records enable packet
observation. Denied requests that intentionally do not create or
change an Ash resource MUST still emit a durable standard audit event.
Audit-producing Ash actions MUST receive an explicit request id in the
action context; implementations MUST reject or fail closed when the
request id is missing instead of falling back to process-local logger
metadata.

#### Scenario: Remote capture request is versioned
- **WHEN** an operator requests a remote capture session
- **THEN** the `RemotePacketCaptureSession` create action records an
  AshPaperTrail version with actor id, partition id, agent id,
  requested interfaces, normalized BPF filter metadata, requested
  duration, requested snaplen, requested byte cap, and request id
- **AND** the audit feed exposes a link or identifier for the
  AshPaperTrail-backed audit record

#### Scenario: Capture posture changes are versioned
- **WHEN** an operator changes a visibility profile or capture
  interface allowlist in a way that enables or broadens packet
  observation
- **THEN** the corresponding Ash resource action records an
  AshPaperTrail version containing the prior value, new value, actor
  id, partition id, and request id
- **AND** the change is visible to users holding the audit-view
  permission for that partition

#### Scenario: Denial without resource creation is still audited
- **WHEN** an operator attempts a cross-tenant capture request that is
  denied before a `RemotePacketCaptureSession` record is created
- **THEN** a standard audit event is written with actor id,
  request id, source partition, attempted target agent id, requested
  interfaces, normalized BPF filter metadata, and denial reason

### Requirement: RBAC permissions for remote capture

`serviceradar-core` SHALL expose two new RBAC permissions in
`Serviceradar.Identity.RBAC.Catalog`: `agent_capture:remote` (gates
the ability to request and run a capture session) and
`agent_capture:audit_view` (gates visibility into historic and
in-progress capture sessions). No default role SHALL hold
`agent_capture:remote`; tenant administrators MUST assign it
explicitly.

#### Scenario: Default install grants no remote-capture access
- **WHEN** a fresh ServiceRadar tenant is provisioned
- **THEN** no role automatically holds `agent_capture:remote`
- **AND** any attempt to start a capture session is denied until an
  administrator assigns the permission

#### Scenario: Permission is independently grantable from audit view
- **WHEN** an administrator grants a user `agent_capture:audit_view`
  without `agent_capture:remote`
- **THEN** the user can list and inspect existing sessions
- **AND** the user is denied when attempting to start a new session

### Requirement: Hard-bounded session duration and byte caps

`serviceradar-netprobe` SHALL terminate any capture session whose
elapsed wall time exceeds `duration_s` or whose cumulative pcapng
output exceeds `byte_cap`, regardless of upstream state. On
termination the sidecar MUST emit a final `PcapngBlock` with
`final = true` and a structured termination reason. `core-elx` MUST
independently enforce the same caps; per-partition cap ceilings
MUST be configurable and MUST be respected by the request validator.

#### Scenario: Duration cap terminates an in-flight session
- **WHEN** a session with `duration_s = 30` reaches 30 seconds of
  elapsed wall time without an upstream stop
- **THEN** the sidecar closes the pcap handle within 1 second
- **AND** emits a final `PcapngBlock` with `final = true,
  termination_reason = "duration_cap"`
- **AND** the `RemotePacketCaptureSession` transitions to
  `timed_out`

#### Scenario: Byte cap terminates an in-flight session
- **WHEN** a session's cumulative pcapng output reaches `byte_cap`
- **THEN** the sidecar closes the pcap handle, emits a final
  `PcapngBlock` with `termination_reason = "byte_cap"`, and the
  session record transitions to `completed`

#### Scenario: Request exceeding partition ceiling is rejected
- **WHEN** an operator submits `duration_s = 1200` against a tenant
  whose cap ceiling is 600
- **THEN** the request is rejected at the `core-elx` validator with
  a structured error before any agent-gateway dispatch occurs
- **AND** no session record is created

### Requirement: Per-agent concurrent-session cap

`serviceradar-netprobe` SHALL refuse to start a new capture session
while another session for the same `netprobe` instance is active.
In the v1 contract the per-agent concurrent-session cap is exactly
one; future iterations may raise this cap, but reducing it below
one MUST be considered a breaking change.

#### Scenario: Overlapping session is rejected
- **WHEN** a session is already active on agent A and a second user
  submits a capture request for the same agent
- **THEN** the request is denied with a structured "concurrent
  session cap reached" error
- **AND** the existing session continues uninterrupted

### Requirement: BPF filter compilation gate

`serviceradar-netprobe` SHALL compile the supplied libpcap-style
`bpf_filter` against the requested interfaces before opening any
pcap handle, and MUST refuse to start the session on parse or
compile failure. Compile errors MUST be returned upstream so the
`core-elx` validator can surface them to the requesting user
before the session enters the `active` state.

#### Scenario: Invalid filter prevents session start
- **WHEN** a user submits `bpf_filter = "tpc port 443"` (typo)
- **THEN** the sidecar refuses to start
- **AND** the session record never reaches the `active` state
- **AND** the user receives a structured error naming the BPF parse
  failure

### Requirement: Capture-interface allowlist is shared with passive observation

A remote capture session SHALL be permitted to target only interfaces
present in the agent's `visibility_config.capture_interfaces`
allowlist (defined in `host-network-visibility`). The deny-by-default
posture MUST apply identically; the sidecar MUST refuse `any` and
refuse interfaces missing from the allowlist regardless of session
RBAC grant.

#### Scenario: Capture request for non-allowlisted interface is rejected
- **WHEN** an operator submits a session naming interface `eth2` that
  is not on the agent's allowlist
- **THEN** the agent refuses the session before contacting `netprobe`
- **AND** the session record transitions to `denied` with reason
  `interface_not_allowlisted`

### Requirement: pcapng wire format end-to-end

`serviceradar-netprobe` SHALL emit raw pcapng blocks for each capture
session: a Section Header Block followed by Interface Description
Block(s), then a stream of Enhanced Packet Blocks. Intermediate hops
(agent, agent-gateway, core-elx, web-ng) MUST forward block bytes
unchanged without re-encoding. The `srctl capture` subcommand MUST
write the received pcapng to standard output without modification so
that any standard pcapng reader (`wireshark -k -i -`, `tshark -i -`,
`mergecap`, …) can consume the stream.

#### Scenario: Stream begins with SHB and IDB
- **WHEN** a session enters the `active` state
- **THEN** the first pcapng block emitted by the sidecar is a
  Section Header Block
- **AND** the next block(s) are Interface Description Block(s)
  matching the captured interfaces

#### Scenario: Bytes survive every hop unchanged
- **WHEN** an Enhanced Packet Block is emitted by the sidecar
- **THEN** the bytes that `srctl` writes to standard
  output are byte-identical to the bytes the sidecar emitted

### Requirement: Client-disconnect terminates the upstream session

`web-ng` SHALL detect a client-side close of the streaming endpoint
and propagate cancellation through `core-elx` and `agent-gateway`
to the agent so that `netprobe` terminates the session and frees
the pcap handle within 5 seconds. The session record MUST
transition to `aborted` with `termination_reason = "client_closed"`.

#### Scenario: CLI is killed mid-stream
- **WHEN** an engineer kills `srctl capture` while a
  session is active
- **THEN** `web-ng` observes the stream close
- **AND** within 5 seconds `netprobe`'s pcap handle is closed and
  the session record transitions to `aborted`

### Requirement: `srctl capture` subcommand

`srctl` SHALL accept a `capture` subcommand whose flags are
`--agent`, `--interface`, `--filter`, `--duration`, `--snaplen`,
and `--byte-cap`. (`srctl` is the Go CLI at `go/cmd/cli/`, renamed
from `serviceradar-cli` as part of this proposal.) The subcommand
MUST authenticate using the cached device-code token established
by `srctl auth login` (per `add-cli-device-auth`'s server-side
endpoints). The subcommand MUST write pcapng to standard output
unchanged and MUST surface session metadata (session id, expected
termination time, audit-record URL) on standard error without
polluting standard output.

#### Scenario: Missing local token surfaces a helpful hint
- **WHEN** an engineer runs `srctl capture …` on a
  workstation that has no cached device-code token
- **THEN** the CLI exits non-zero
- **AND** prints a stderr hint instructing the engineer to run
  `srctl auth login --instance …` first

#### Scenario: Pipeable pcapng stream
- **WHEN** an engineer runs
  `srctl capture --agent A --interface eth0 --filter "icmp"
  --duration 5 | tshark -r -`
- **THEN** `tshark` parses the stream as a valid pcapng file
- **AND** session metadata appears on the engineer's terminal via
  stderr without corrupting the pcapng on stdout
