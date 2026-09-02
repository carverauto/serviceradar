## ADDED Requirements

### Requirement: Remote Packet Capture Session Resource

`serviceradar-core` SHALL persist remote capture sessions as
`Serviceradar.Telemetry.RemotePacketCaptureSession` Ash records. Each
record MUST carry `session_id` (ULID), `partition_id`, `agent_id`,
`target_interfaces`, `capture_filter`, `snaplen`, `duration_s`,
`byte_cap`, `direction`, `requested_by_user_id`, `requested_at`, `state`
(one of `requested`, `authorised`, `active`, `completed`, `aborted`,
`timed_out`, `denied`), `bytes_streamed`, `packets_captured`,
`packets_dropped`, and `last_block_at`. Sessions MUST be
partition-scoped via `Ash.Policy.Authorizer` such that a user holding the
requesting permission in one partition cannot target an agent in another.
The resource MUST enable AshPaperTrail so every create, update and
terminal state transition has a durable version record.

#### Scenario: Cross-partition session is denied
- **WHEN** a user with `agent_capture:remote` in partition A submits a
  capture request naming an agent belonging to partition B
- **THEN** the request is denied
- **AND** no `RemotePacketCaptureSession` record is created in either
  partition
- **AND** a durable audit record of the denial is written

#### Scenario: Every state transition is audit-logged
- **WHEN** a session moves from any state to any other state
- **THEN** AshPaperTrail records a version carrying the prior state, the
  new state, the transition reason, the actor, the partition, the request
  id, the agent id, the target interfaces, the filter metadata, and the
  bytes streamed at the time of the transition

### Requirement: Invasive Operator Action Audit Trail

`serviceradar-core` SHALL write a durable audit event for every remote
capture request, including requests denied before any session resource is
created. A denial that mutates no resource MUST still produce an audit
event; absence of a resource MUST NOT mean absence of a record.

#### Scenario: Denial before resource creation is still audited
- **WHEN** a malformed capture request is rejected by the validator
  before a session record exists
- **THEN** a standard audit event is written naming the actor, the
  partition, the requested agent, and the rejection reason

### Requirement: RBAC permissions for remote capture

Remote capture SHALL be gated by two independently grantable permissions
in `Serviceradar.Identity.RBAC.Catalog`: `agent_capture:remote` to start
a session, and `agent_capture:audit_view` to list and inspect existing
sessions. Neither permission MAY be granted to any role by default.

#### Scenario: Capture is denied without the permission
- **WHEN** a user without `agent_capture:remote` attempts to start a
  capture session
- **THEN** the attempt is denied until an administrator grants the
  permission
- **AND** the denial is audited

#### Scenario: Audit view is independently grantable
- **WHEN** an administrator grants `agent_capture:audit_view` without
  `agent_capture:remote`
- **THEN** the user can list and inspect existing sessions
- **AND** the user is denied when attempting to start a new session

### Requirement: Hard-bounded session duration and byte caps

`serviceradar-netprobe` SHALL terminate any capture session whose elapsed
wall time exceeds `duration_s` or whose cumulative pcapng output exceeds
`byte_cap`, regardless of upstream state. On termination the sidecar MUST
emit a final `PcapngBlock` with `final = true` and a structured
termination reason. `serviceradar-core` MUST independently enforce the
same caps, and per-partition cap ceilings MUST be configurable and
respected by the request validator.

#### Scenario: Duration cap terminates an in-flight session
- **WHEN** a session with `duration_s = 30` reaches 30 seconds of elapsed
  wall time without an upstream stop
- **THEN** the sidecar stops the capture within 1 second
- **AND** emits a final `PcapngBlock` with `final = true`,
  `termination_reason = duration_cap`
- **AND** the session record transitions to `timed_out`

#### Scenario: Byte cap terminates an in-flight session
- **WHEN** a session's cumulative pcapng output reaches `byte_cap`
- **THEN** the sidecar stops the capture, emits a final `PcapngBlock`
  with `termination_reason = byte_cap`, and the session record
  transitions to `completed`

#### Scenario: Request exceeding the partition ceiling is rejected
- **WHEN** an operator submits `duration_s = 1200` against a partition
  whose ceiling is 600
- **THEN** the request is rejected by the `serviceradar-core` validator
  with a structured error before any agent-gateway dispatch occurs
- **AND** no session record is created

### Requirement: Per-agent concurrent-session cap

`serviceradar-netprobe` SHALL refuse to start a capture session while
another session is active on the same instance. The v1 cap is exactly
one, and a rejected overlapping request MUST be distinguishable from
every other rejection reason.

#### Scenario: Overlapping session is rejected distinguishably
- **WHEN** a second capture session is requested while one is active
- **THEN** the sidecar refuses the second request
- **AND** the refusal names the concurrent-session cap rather than a
  generic failure
- **AND** the in-flight session is unaffected

### Requirement: One filter mechanism behind two front doors

Capture filters SHALL be enforced as classic BPF attached to the capture
socket, whichever front door supplied them. A client speaking RPCAP
supplies a compiled cBPF program, which MUST be attached unchanged after
a length check. A client supplying a filter string MUST have it compiled
by `serviceradar-netprobe` from a documented tcpdump subset: `ip`, `ip6`,
`tcp`, `udp`, `icmp`, `icmp6`, `arp`, `host <ip>`, `net <cidr>`,
`port <n>`, `portrange <a>-<b>`, the `src` and `dst` qualifiers,
`inbound` and `outbound`, and `and`, `or` and `not` over those terms.

The compiler MUST NOT widen a filter it did not fully understand. A
filter that cannot be represented exactly MUST be rejected with a
structured error naming the unsupported construct, never approximated.

#### Scenario: Invalid filter prevents session start
- **WHEN** a user submits the filter `tpc port 443`
- **THEN** the sidecar refuses to start
- **AND** the session record never reaches the `active` state
- **AND** the user receives a structured error naming the parse failure

#### Scenario: Unsupported construct is named, not approximated
- **WHEN** a user submits the filter `tcp[13] & 2 != 0`
- **THEN** the request is rejected with an error naming the unsupported
  construct
- **AND** no session is started with a broader filter in its place

#### Scenario: Compiled subset matches libpcap semantics
- **WHEN** a filter string within the supported subset is compiled by
  `serviceradar-netprobe`
- **THEN** the resulting program selects the same packets, over the same
  fixture capture, as libpcap's own compilation of that string

#### Scenario: Oversized compiled program is refused
- **WHEN** a client supplies a compiled cBPF program exceeding the
  permitted instruction count
- **THEN** the session is refused before the program is attached

### Requirement: Capture-interface allowlist is shared with passive observation

A remote capture session SHALL target only interfaces present in the
agent's `visibility_config.capture_interfaces` allowlist. The
deny-by-default posture MUST apply identically to capture: the sidecar
MUST refuse `any`, refuse wildcards, and refuse interfaces missing from
the allowlist regardless of the requesting user's RBAC grant.

#### Scenario: Capture request for a non-allowlisted interface is rejected
- **WHEN** an operator submits a session naming interface `eth2` that is
  not on the agent's allowlist
- **THEN** the request is refused before `netprobe` starts a capture
- **AND** the session record transitions to `denied` with reason
  `interface_not_allowlisted`

### Requirement: pcapng wire format end-to-end

`serviceradar-netprobe` SHALL emit raw pcapng blocks for each capture
session: a Section Header Block, followed by one Interface Description
Block per captured interface, followed by a stream of Enhanced Packet
Blocks. Interface Description Blocks MUST declare `if_tsresol = 9` and
Enhanced Packet Block timestamps MUST be wall-clock, converted from the
kernel monotonic clock the capture hook stamps.

Intermediate hops -- agent, agent-gateway, `serviceradar-core`, `web-ng`
-- MUST forward block bytes unchanged without re-encoding. `srctl
capture` MUST write the received pcapng to standard output without
modification, so that any standard pcapng reader can consume the stream.

#### Scenario: Stream begins with SHB and IDB
- **WHEN** a session enters the `active` state
- **THEN** the first block emitted is a Section Header Block
- **AND** the next blocks are Interface Description Blocks matching the
  captured interfaces

#### Scenario: Bytes survive every hop unchanged
- **WHEN** an Enhanced Packet Block is emitted by the sidecar
- **THEN** the bytes `srctl` writes to standard output are byte-identical
  to the bytes the sidecar emitted

#### Scenario: Standard tooling reads the stream
- **WHEN** an operator pipes `srctl capture` into `tshark -r -`
- **THEN** the packets are decoded without a format error
- **AND** their timestamps fall within the session's wall-clock window

### Requirement: Dropped packets are reported, never silent

When the kernel capture ring overflows, `serviceradar-netprobe` SHALL
count the dropped frames and report the count both as a sidecar metric
and in the session's terminal `PcapngBlock`. A session that dropped
packets MUST NOT present as a complete capture.

#### Scenario: Ring overflow is surfaced to the operator
- **WHEN** the capture ring overflows during a session
- **THEN** the drop counter increments
- **AND** the terminal `PcapngBlock` reports a non-zero `packets_dropped`
- **AND** the session record and the capture history view show the drop
  count

### Requirement: Client-disconnect terminates the upstream session

A client stream close SHALL propagate upstream and stop the capture at
the sidecar. No capture may outlive the client that requested it.

#### Scenario: Killed client stops the capture
- **WHEN** `srctl capture` is killed mid-stream
- **THEN** the agent-side session is terminated within 5 seconds
- **AND** the session record transitions to `aborted`

### Requirement: `srctl capture` subcommand

The Go CLI SHALL provide a `capture` subcommand accepting `--agent`,
`--interface`, `--filter`, `--duration`, `--snaplen` and `--byte-cap`,
authenticating with the device-code JWT issued by `add-cli-device-auth`.
Standard output MUST carry only pcapng bytes; all session metadata MUST
go to standard error. Exit codes MUST distinguish failure modes: 0
graceful completion, 10 auth failure, 11 RBAC denial, 12 filter parse
failure, 13 agent unreachable, 14 session cap exhausted, 15 upstream
cancellation.

#### Scenario: Missing credentials refuse before dispatch
- **WHEN** `srctl capture` runs with no cached token or an expired one
- **THEN** it exits 10 without contacting an agent
- **AND** prints a stderr hint to run `srctl auth login`

#### Scenario: Standard output carries only packet bytes
- **WHEN** a session completes successfully with stderr redirected
  elsewhere
- **THEN** standard output parses as a pcapng stream with no leading or
  trailing non-pcapng bytes

### Requirement: Remote capture is reachable by stock Wireshark over TLS

ServiceRadar SHALL expose an RPCAP listener so that unmodified Wireshark
can capture from an agent without installing a plugin. The listener MUST
require TLS (`rpcaps://`) and MUST refuse to complete an unencrypted
handshake, because RPCAP transmits credentials in clear text otherwise.
It MUST refuse `RPCAP_RMTAUTH_NULL`; anonymous capture is never
permitted. It MUST be disabled by default.

Authentication MUST use a scoped capture token bound to a single
partition, carrying the capture permission, with an expiry, revocable,
and stored hashed. A user's account password MUST NOT be accepted.

#### Scenario: Wireshark captures over rpcaps
- **WHEN** an operator adds a ServiceRadar remote interface in Wireshark
  with TLS enabled and authenticates with a valid capture token
- **THEN** the agent's allowlisted interfaces are offered as capture
  sources
- **AND** starting a capture streams live packets into Wireshark

#### Scenario: Plaintext and anonymous access are refused
- **WHEN** a client connects without TLS, or authenticates with
  `RPCAP_RMTAUTH_NULL`
- **THEN** the connection is refused before any capture is authorized
- **AND** the refusal is audited with the source address

#### Scenario: Out-of-band data channels are refused
- **WHEN** a client requests a datagram data channel or a separate data
  connection not bound to the authenticated session
- **THEN** the request is refused
- **AND** no packet data is transmitted outside the authenticated,
  encrypted connection

### Requirement: Interface enumeration is scoped to the actor

The RPCAP `FINDALLIF` response SHALL contain only the agents and
allowlisted interfaces the authenticated actor is permitted to capture
on. Enumeration MUST NOT disclose agents, interfaces or partitions
outside the actor's grant.

#### Scenario: Enumeration does not leak the fleet
- **WHEN** an authenticated actor whose grant covers one agent in one
  partition enumerates interfaces
- **THEN** only that agent's allowlisted interfaces are returned
- **AND** no agent from another partition appears in the response

### Requirement: The capture front doors share one authorization path

Every front door -- `srctl`, the Web UI, and the RPCAP listener -- SHALL
authorize capture requests through the same `serviceradar-core` action,
so that partition scoping, cap ceilings, AshPaperTrail versions and
denial audit events apply identically regardless of entry point. A front
door MUST NOT implement authorization logic of its own.

#### Scenario: A denial is identical across front doors
- **WHEN** the same unauthorized capture is attempted from `srctl` and
  from the RPCAP listener
- **THEN** both are denied for the same reason
- **AND** both produce a durable audit event naming the actor, the
  partition and the requested agent

### Requirement: Capture retention is opt-in and payloads are not stored in rows

Captured bytes SHALL NOT be persisted by default: a session streams to
its requesting client and only session metadata and audit records are
retained. A requester holding the retention permission MAY mark a session
retained, in which case the pcapng payload MUST be written to the
configured object store and the session record MUST carry a manifest, a
storage pointer and a retention expiry. Payload bytes MUST NOT be stored
in a database row.

#### Scenario: Unretained session leaves no payload behind
- **WHEN** a session completes without retention requested
- **THEN** no capture payload exists in the object store
- **AND** the session record and audit trail still describe the session

#### Scenario: Retained session is downloadable and expires
- **WHEN** a session is retained and later downloaded
- **THEN** the stored object parses as pcapng
- **AND** after the retention expiry the object is deleted and the record
  states that it was

#### Scenario: Retention without the permission is denied
- **WHEN** a requester without the retention permission asks for a
  retained session
- **THEN** the request is denied
- **AND** the denial is audited
