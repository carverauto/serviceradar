# Tasks

Eleven implementation slices plus a bookkeeping slice, each one PR. `S0`
blocks everything. `S4` depends on none of `S1`-`S3` and can run in
parallel with them. `S6` depends on `S4`. Everything else is serial.
`S11` is documentation only and can land at any point after `S0`.

Task numbers in parentheses, like `(22.3)`, name the
`add-host-network-visibility-sidecar` Phase 5 task this replaces or
carries forward. Where the text differs from that task, the difference is
deliberate and `design.md` says why.

**Every acceptance criterion must be able to fail.** Gate on the
artefact, not on the job: a capture session that reports success while
writing zero packets is the failure shape this repository keeps
re-learning.

## S0. Wire contract and the gate that protects it

Blocks every other slice.

- [ ] 0.1 Add a `reserved` statement to `NetprobeFrame`
  (`proto/agent/netprobe/v1/netprobe.proto:26-52`) with a comment naming
  each reservation, following the convention at
  `proto/monitoring.proto:218,254,276,307` and `netprobe.proto`'s own
  `VisibilityAgentConfig:118-121`. Reservations go on the enclosing
  message; proto3 forbids them inside a `oneof`. (GitHub #4026)
- [ ] 0.2 Add a `breaking:` section to `buf.yaml` and a `buf breaking`
  step to the proto CI gate, against the merge base. Today `buf.yaml`
  declares `lint` only and `make proto-lint` is `buf lint`.
- [ ] 0.3 Prove the gate can fail: a check that reuses a reserved tag and
  asserts `buf breaking` rejects it. A gate nobody has seen fail is
  indistinguishable from one that is not wired up.
- [ ] 0.4 Add a loud unknown-arm branch to the agent `readLoop`
  (`go/pkg/agent/netprobe/client.go`), which today has no default branch
  and would drop an unrecognized oneof arm with no log, no metric and no
  `recordEventDrop`. (GitHub #4026)
- [ ] 0.5 Define `StartRemoteCapture`: `session_id` (ULID),
  `interfaces` (repeated), `filter_expression` (string, the `srctl`
  form), `filter_bpf` (repeated compiled instruction, the RPCAP form --
  exactly one of the two is set), `snaplen`, `duration_s`, `byte_cap`,
  `direction`, `promiscuous`. (22.1)
- [ ] 0.6 Define `PcapngBlock`: `session_id`, `bytes` (raw pcapng,
  never re-encoded), `final`, `termination_reason` (enum:
  `duration_cap`, `byte_cap`, `client_cancel`, `agent_disconnect`,
  `filter_error`, `interface_down`), `packets_captured`,
  `packets_dropped`, `bytes_streamed`. (22.1)
- [ ] 0.7 Regenerate both committed trees: `netprobe.pb.go`
  (`Makefile:623-625`) and `netprobe.pb.ex` (`Makefile:677`). Rust needs
  no committed change; `rust/netprobe/build.rs` regenerates via prost at
  build time.
- [ ] 0.8 `make proto-lint` and `make verify-proto-elixir` clean. The
  latter is a `git diff --exit-code` drift gate (`Makefile:685-690`) and
  fails if 0.7 was skipped.

## S1. netprobe AF_PACKET capture engine

The packet path. No IPC surface yet -- provable on its own.

- [ ] 1.1 Open an `AF_PACKET`/`SOCK_RAW` socket bound to the target
  ifindex with a TPACKET_V3 `PACKET_MMAP` ring, sized per session.
- [ ] 1.2 Attach the session filter with `SO_ATTACH_FILTER` before the
  first frame can be queued, so no unfiltered packet is ever ringed.
- [ ] 1.3 Write the tcpdump-subset to cBPF compiler for the `srctl`
  string form: the grammar in `design.md` D2. Unsupported constructs
  return a structured error naming the construct. It MUST NOT widen a
  filter it did not fully understand.
- [ ] 1.4 Accept a pre-compiled cBPF program (the RPCAP form) and attach
  it unchanged, bounding program length and refusing oversized programs
  before attach. The kernel validates the program on attach.
- [ ] 1.5 Write the pcapng encoder: Section Header Block, one Interface
  Description Block per captured interface with `if_tsresol = 9`, then
  Enhanced Packet Blocks carrying the ring's `tp_sec`/`tp_nsec`. (22.4)
- [ ] 1.6 Record frame direction from `PACKET_OUTGOING` so a session can
  request ingress, egress or both.
- [ ] 1.7 Enforce `duration_s` and `byte_cap`; emit a terminal
  `PcapngBlock` with `final = true` and the termination reason on either
  cap or on graceful stop. (22.5)
- [ ] 1.8 Poll `PACKET_STATISTICS` for `tp_drops`; expose it as a
  netprobe metric and carry it in the terminal block. (`design.md` D7)
- [ ] 1.9 Unit tests: the compiler accepts every documented form and
  rejects `tcp[13] & 2 != 0`, `vlan` and a bare typo with a named error;
  encoder output parses under an independent pcapng reader; both caps
  fire.
- [ ] 1.10 Integration test on loopback: generate real ICMP, capture with
  `filter = "icmp"`, decode with an independent reader, assert the ICMP
  packets are present **and** that a non-matching flow on the same
  interface is absent. Both halves matter -- the second is what proves
  the filter does anything.
- [ ] 1.11 Differential test: compile a set of filter strings with the
  compiler from 1.3 and assert the resulting cBPF selects the same
  packets as libpcap's own compilation of the same string, over a fixture
  pcap. This is the only real check that the subset means what tcpdump
  means.
- [ ] 1.12 Force a ring-full condition; assert `tp_drops` is non-zero and
  the terminal block reports it.
- [ ] 1.13 Measure capture cost: sustained packets/second and CPU at a
  realistic rate, recorded in this change.

## S2. netprobe capture session RPC

- [ ] 2.1 Activate `CaptureSessions(StartRemoteCapture) returns (stream
  PcapngBlock)` on the netprobe IPC surface, driving the S1 session.
  (22.1)
- [ ] 2.2 Validate the request against `capture_interfaces`; reject
  anything not allowlisted, plus `any` and wildcards, reusing
  `validate_interface` (`rust/netprobe/src/config.rs:119`). (22.2)
- [ ] 2.3 Reject uncompilable filters with the structured error from 1.3
  before the session starts. (22.3, corrected: no `pcap` crate)
- [ ] 2.4 Concurrent-session cap of exactly 1 per netprobe instance;
  reject overlapping requests distinguishably. (22.6)
- [ ] 2.5 On agent UDS disconnect mid-session, terminate and free the
  socket and ring within 5 s. (22.7)
- [ ] 2.6 Implement `SO_PEERCRED` on the netprobe UDS. Sidecar task 3.2
  is HALF DONE -- mode 0600 landed and `SO_PEERCRED` never did, which
  makes file permissions the entire authorization story for a socket that
  can now start packet captures.
- [ ] 2.7 Tests: allowlist denial, filter-compile failure, duration cap,
  byte cap, mid-session UDS close, concurrent-session rejection. (22.8)

## S3. Agent to agent-gateway transport

Modelled on the camera relay (`design.md` D4).

- [ ] 3.1 Add a `RemotePacketCapture` gRPC service to the agent to
  agent-gateway proto: `Stream(StartRemoteCaptureSession) returns (stream
  RemotePacketCaptureFrame)`, the frame a oneof of `PcapngBlock` and
  `SessionStateChanged`. (23.1, 27.1)
- [ ] 3.2 Prove the RPC multiplexes onto the existing mTLS HTTP/2
  connection: assert no second TCP or TLS session is opened. (23.2)
- [ ] 3.3 Implement `go/pkg/agent/netprobe/capture.go`: receive the gRPC
  stream, open the netprobe `CaptureSessions` UDS RPC, forward
  `PcapngBlock` frames between them without re-encoding. (23.3)
- [ ] 3.4 Add the gateway-side server and forwarder, mirroring
  `camera_media_server.ex` and `camera_media_forwarder.ex`: one
  `:rpc.call` into core-elx on session open with `:nodedown` retry, then
  stream to the returned ingress pid over ERTS.
- [ ] 3.5 Count bytes per session in the agent and emit
  `SessionStateChanged` at 1 Hz so upstream tracks `bytes_streamed`
  without decoding pcapng. (23.4)
- [ ] 3.6 Propagate gateway-initiated cancellation to netprobe within
  1 s. (23.5)
- [ ] 3.7 Surface an active-capture indicator in the agent status
  response. (23.6)

## S4. core-elx ingress session, lifecycle, RBAC, audit

Parallelizable with S1-S3.

- [ ] 4.1 Add the supervised ingress session and tracker, mirroring
  `camera_media_ingress.ex` / `camera_media_ingress_session.ex`: allocate
  on open, own fan-out and byte accounting, terminate on any cap or
  disconnect.
- [ ] 4.2 Create the `Serviceradar.Telemetry.RemotePacketCaptureSession`
  Ash resource per the D13b attribute list. (24.1)
- [ ] 4.3 Generate the migration with `mix ash.codegen
  add_remote_packet_capture_session`; apply with `mix ash.migrate`.
  Tables and indexes go in the `platform` schema. (24.2)
- [ ] 4.4 Add actions `request_capture`, `transition_state`, `complete`,
  `abort`. Keep them atomic; implement `atomic/3` rather than reaching
  for `require_atomic? false`. (24.3)
- [ ] 4.5 Add `agent_capture:remote`, `agent_capture:audit_view` and
  `agent_capture:retain` to `Serviceradar.Identity.RBAC.Catalog`, granted
  to nobody by default. (24.4)
- [ ] 4.6 Add resource policies enforcing the permissions per partition.
  (24.5)
- [ ] 4.7 Enable AshPaperTrail; every transition carries actor,
  partition, request id, agent id, interfaces, filter metadata,
  duration, snaplen, byte cap and bytes streamed. A missing request id
  fails validation rather than falling back to `Logger.metadata`. (24.6)
- [ ] 4.8 Per-partition ceilings on `duration_s`, `byte_cap` and
  concurrent sessions, enforced in the validator before dispatch. (24.10)
- [ ] 4.9 Emit a durable standard audit event for denied invasive actions
  that create no Ash resource: cross-partition attempts and malformed
  requests rejected before session creation. (24.11)
- [ ] 4.10 Tests: a PaperTrail version exists for every transition; and a
  denial test proving an audit event is written when **no** session
  resource is created. (24.12)

## S5. Opt-in retention

- [ ] 5.1 Add retention fields to the session resource mirroring
  `remote_access_recordings`: `storage_backend` (default
  `datasvc_object_store`), `storage_bucket`, `object_key`, `manifest`,
  `retention_expires_at`, byte counters. Payload bytes never go in a row.
- [ ] 5.2 Fan out in the ingress session: when a session is marked
  retained, write pcapng to the object store alongside streaming it to
  the client. Default is live-only.
- [ ] 5.3 Gate retention on `agent_capture:retain` and the partition
  retention policy; a request for retention without the permission is
  denied and audited.
- [ ] 5.4 Encrypt the manifest through AshCloak, as
  `20260518143000_encrypt_remote_access_recordings` does.
- [ ] 5.5 Add the retention expiry job; expired objects are deleted and
  the row records the deletion.
- [ ] 5.6 Tests: a retained session's object downloads and parses as
  pcapng; an unretained session leaves no object behind; an expired
  object is gone and the row says so.

## S6. `rpcaps://` listener -- the Wireshark front door

Depends on S4. Security posture is `design.md` D3; each refusal below is
a spec requirement, not an implementation detail.

- [ ] 6.1 Add the TCP acceptor on `ThousandIsland` (arrives with Bandit,
  `elixir/web-ng/mix.exs:157`). No raw-TCP listener exists in this
  codebase today, so TLS termination, connection limits and shutdown need
  their own tests.
- [ ] 6.2 Implement the RPCAP framing: `struct rpcap_header {ver, type,
  value, plen}` and the message set `FINDALLIF`, `OPEN`, `STARTCAP`,
  `UPDATEFILTER`, `CLOSE`, `PACKET`, `AUTH`, `STATS`, `ENDCAP`, with
  replies flagged `| 0x80`.
- [ ] 6.3 Require TLS: refuse to complete an unencrypted handshake.
  Plaintext `rpcap://` is rejected before authentication.
- [ ] 6.4 Refuse `RPCAP_RMTAUTH_NULL`. Anonymous capture is never
  permitted.
- [ ] 6.5 Add scoped capture tokens: minted in Settings, bound to one
  partition, carrying `agent_capture:remote`, with an expiry, revocable,
  shown once, stored hashed. `RPCAP_RMTAUTH_PWD` carries the token, never
  an account password.
- [ ] 6.6 Resolve the token to an actor and call the same
  `request_capture` action the CLI and UI call. The listener holds no
  authorization logic of its own.
- [ ] 6.7 Scope `FINDALLIF` to the agents and allowlisted interfaces that
  actor may capture on. The natural implementation returns the whole
  fleet and leaks agent inventory.
- [ ] 6.8 Refuse `RPCAP_STARTCAPREQ_FLAG_DGRAM` and any separate data
  connection not bound to the authenticated session by a one-time token,
  including `RPCAP_STARTCAPREQ_FLAG_SERVEROPEN`.
- [ ] 6.9 Rate-limit and lock out authentication failures using the
  `RateLimiter` from `add-cli-device-auth`; audit successful and failed
  authentications with the source address.
- [ ] 6.10 Translate pcapng Enhanced Packet Blocks to `RPCAP_MSG_PACKET`
  with `struct rpcap_pkthdr`, and answer `RPCAP_MSG_STATS_REQ` with the
  session's captured and dropped counts. Document that this path
  truncates nanosecond timestamps to microseconds -- a property of RPCAP.
- [ ] 6.11 Abort the session when the control connection drops.
- [ ] 6.12 Ship the listener disabled by default, with explicit bind
  configuration and documentation that exposing it requires provisioning
  a TCP load balancer or NodePort on purpose.
- [ ] 6.13 End-to-end test with stock Wireshark or `rpcapd`-compatible
  libpcap: capture succeeds over `rpcaps://`, and each of plaintext, NULL
  auth, UDP data and a wrong-partition agent is refused with the right
  error.

## S7. web-ng edge for the CLI and the browser

- [ ] 7.1 Phoenix Channel endpoint authenticating the client against the
  device-code JWT from `add-cli-device-auth` (landed), dispatching to
  core-elx over ERTS RPC for RBAC, audit and session creation, then
  proxying pcapng bytes unchanged. (24.7)
- [ ] 7.2 WebSocket endpoint for the browser live view, sharing the same
  ingress session. This is the UI's transport; it is not a Wireshark
  transport, because Wireshark has no WebSocket capture input.
- [ ] 7.3 Client-disconnect detection: on client stream close, propagate
  over ERTS RPC so core-elx stops the agent session and transitions the
  record to `aborted`. (24.9)
- [ ] 7.4 Test: kill the client mid-stream, assert the agent-side session
  ends within 5 s and the record reaches `aborted`.

## S8. `srctl` CLI

See `design.md`, "Open question for review" -- the rename in 8.1-8.4 is
separable from capture if you would rather not couple it.

- [ ] 8.1 Rename the Go CLI Bazel target so the packaged binary is
  `srctl`; source stays at `go/cmd/cli/`. (25.1)
- [ ] 8.2 Update deb/rpm/tarball/OCI packaging to install `srctl` and
  create a `serviceradar-cli` compatibility symlink. (25.2)
- [ ] 8.3 Update `docs/docs/edge-agent-onboarding.md`,
  `agent-configuration.md`, `web-ui-overview.md`,
  `agent-release-management.md` and `docs/CNCF/*` to `srctl`, with a
  one-time call-out that `serviceradar-cli` is a deprecated alias. (25.3)
- [ ] 8.4 Release-notes entry: the rename, the one-release symlink compat
  window, the deprecation. (25.4)
- [ ] 8.5 `auth` subcommand group -- `login`, `status`, `logout` -- over
  the RFC 8628 device-code endpoints landed by `add-cli-device-auth`.
  (25.5-25.8)
- [ ] 8.6 Persist the JWT at the OS-appropriate path with mode 0600.
  (25.7)
- [ ] 8.7 `capture` subcommand taking `--agent`, `--interface`,
  `--filter`, `--duration`, `--snaplen`, `--byte-cap`, `--retain`.
  (25.10)
- [ ] 8.8 Refuse to start with a missing or expired token, printing a
  stderr hint to run `srctl auth login`. (25.11)
- [ ] 8.9 Stream pcapng to stdout with direct `os.Stdout.Write`; no
  encoder, buffer or Writer that translates. (25.12, 25.13)
- [ ] 8.10 Session metadata to stderr only. Stdout carries only pcapng
  bytes. (25.14)
- [ ] 8.11 Exit 0 on graceful completion; 10 auth failure, 11 RBAC
  denial, 12 filter parse failure, 13 agent unreachable, 14 session cap
  exhausted, 15 upstream cancellation. (25.15)
- [ ] 8.12 Test that stdout is byte-pure: pipe it to a pcapng reader and
  assert it parses, with stderr redirected elsewhere.
- [ ] 8.13 Document `srctl capture | wireshark -k -i -` and the
  `rpcaps://` route in the runbook. (25.16)

## S9. Web UI and agent registry

- [ ] 9.1 "Start Remote Capture" action on Agent Detail, and on Device
  Detail when the device is an agent host, guarded by
  `agent_capture:remote`. (26.1)
- [ ] 9.2 Request modal collecting interface, filter, `duration_s`,
  `snaplen`, `byte_cap` and retention; pre-fill allowlisted interfaces;
  reject values over the partition ceiling inline. (26.2)
- [ ] 9.3 Active-session card: session id, elapsed, bytes streamed,
  packets dropped, filter, Stop. (26.3)
- [ ] 9.4 Capture history behind `agent_capture:audit_view`, with a
  download for retained sessions. (26.4)
- [ ] 9.5 Capture-token management in Settings: mint, list, revoke, with
  the token shown once.
- [ ] 9.6 Active-session indicator on the Agent Detail capability badge.
  (26.5)
- [ ] 9.7 Add `remote-packet-capture` to the agent capability vocabulary;
  advertise `enabled` where available, `unavailable` otherwise. (27.2)
- [ ] 9.8 Surface active-session state on the agent registry record.
  (27.3)
- [ ] 9.9 Playwright: request modal, active-session card, history,
  token management, RBAC denial. (26.6)

## S10. End-to-end validation

- [ ] 10.1 A user with `agent_capture:remote` runs `srctl capture --agent
  <id> --interface eth0 --filter "icmp" --duration 5`, observes pcapng on
  stdout, and `tshark -r -` confirms ICMP packets are present. (28.1)
- [ ] 10.2 The same capture driven from stock Wireshark over `rpcaps://`,
  selected from the Remote Interfaces dialog.
- [ ] 10.3 A user without the permission is denied with a non-zero exit
  code and an audit record is written, on both front doors. (28.2)
- [ ] 10.4 Cap enforcement: duration overrun, byte overrun,
  concurrent-session collision. (28.3)
- [ ] 10.5 Mid-stream client disconnect on both front doors: verify the
  agent-side session ends within 5 s and the record reaches `aborted`.
  (28.4)
- [ ] 10.6 Auditability: start and stop a capture, then verify the audit
  feed renders AshPaperTrail-backed entries for request, start and stop
  with actor, partition, agent id, interfaces, filter metadata, byte
  count and termination reason. (28.5)

## S11. Supersession bookkeeping

- [ ] 11.1 Annotate Phase 5 sections 22-28 of
  `add-host-network-visibility-sidecar/tasks.md` as superseded by this
  change, in the style that file already uses for corrected tasks. Do not
  delete them -- the annotation is the record of why the design changed.
- [ ] 11.2 Add a supersession banner to that change's
  `specs/remote-packet-capture/spec.md` and
  `specs/agent-connectivity/spec.md` deltas pointing here.
- [ ] 11.3 Update `migrate-netprobe-to-native-addon/tasks.md:72`, which
  defers capture-active add-on status reporting on the grounds that
  `StartRemoteCapture` is a Phase-5 TODO. That stops being accurate when
  S0 lands.
- [ ] 11.4 Close GitHub #4025 and #4026 with references to the slices
  that resolved them.
