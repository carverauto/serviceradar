# Tasks

Eleven implementation slices plus a bookkeeping slice, each one PR. `S0`
blocks everything. `S4` depends on none of `S1`-`S3` and can run in
parallel with them. `S5` depends on `S4`, and `S7` depends on `S5` --
a front door must not exist before the audit trail behind it does.
Everything else is serial. `S11` is documentation only and can land at
any point after `S0`.

The `srctl` CLI is **out of scope** for this change; see `design.md`,
"Out of scope: the `srctl` CLI". Wireshark over `rpcaps://` and the Web
UI are the front doors.

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

- [x] 0.1 **CORRECTED while implementing.** The task said to add a
  `reserved` statement to `NetprobeFrame`. That would have been wrong:
  in this repository `reserved` names fields that were *removed*
  (`proto/monitoring.proto:218` -- "Removed: deployment identifiers"),
  and `NetprobeFrame` has removed nothing. Reserving its unused tags
  8-19 would permanently burn tags that were never used. What landed
  instead is a documented tag-discipline comment on the oneof stating
  that removing an arm requires a reservation naming the freed tag, and
  pointing at the gate that enforces it. The enforcement is 0.2-0.3.
  (GitHub #4026)
- [x] 0.2 Added a `breaking:` section to `buf.yaml` (`WIRE_JSON`, chosen
  over `WIRE` because the generated Go and Elixir trees are committed, so
  a rename is a real break here; and over `FILE`, which would forbid
  moving a message between files) plus a `make proto-breaking` target and
  a `buf breaking` step in `.github/workflows/golangci-lint.yml` beside
  the existing `buf lint`. The checkout there needed `fetch-depth: 0`:
  the default depth of 1 leaves the base ref absent and the comparison
  silently has nothing to diff against.
- [x] 0.3 Gate proven to fail, not merely to pass on a clean tree:
  removing `start_remote_capture` and reusing tag 24 for a different
  message type exits 2 with
  `Field "24" ... changed type from ... StartRemoteCapture to ...
  DpiEvent`, and restoring the arm returns it to exit 0.
- [x] 0.4 Add a loud unknown-arm branch to the agent `readLoop`
  (`go/pkg/agent/netprobe/client.go`), which today has no default branch
  and would drop an unrecognized oneof arm with no log, no metric and no
  `recordEventDrop`. (GitHub #4026)
- [x] 0.5 Define `StartRemoteCapture`: `session_id` (ULID),
  `interfaces` (repeated), `filter_expression` (string, the UI/API
  form), `filter_bpf` (repeated compiled instruction, the RPCAP form --
  exactly one of the two is set), `snaplen`, `duration_s`, `byte_cap`,
  `direction`, `promiscuous`. (22.1)
- [x] 0.6 Define `PcapngBlock`: `session_id`, `bytes` (raw pcapng,
  never re-encoded), `final`, `termination_reason` (enum:
  `duration_cap`, `byte_cap`, `client_cancel`, `agent_disconnect`,
  `filter_error`, `interface_down`), `packets_captured`,
  `packets_dropped`, `bytes_streamed`. (22.1)
- [x] 0.7 Regenerate both committed trees: `netprobe.pb.go`
  (`Makefile:623-625`) and `netprobe.pb.ex` (`Makefile:677`). Rust needs
  no committed change; `rust/netprobe/build.rs` regenerates via prost at
  build time.
- [x] 0.8 `make proto-lint` and `make verify-proto-elixir` clean. The
  latter is a `git diff --exit-code` drift gate (`Makefile:685-690`) and
  fails if 0.7 was skipped. Note for anyone repeating this in a fresh
  worktree: run `mix deps.get` in `elixir/serviceradar_core` FIRST. Without
  it the trailing `mix format` aborts with `Unknown dependency :ash` and
  generation leaves raw `protoc-gen-elixir` output, which rewrites ten
  unrelated `.pb.ex` files (`rpc(:Get, ...)` for the committed
  `rpc :Get, ...`) and looks exactly like generator drift. Do not borrow
  `deps` from another checkout -- a different Styler silently reformats.

**Gap found while implementing S0, deliberately not fixed here.** There is
a drift gate for the generated Elixir tree (`verify-proto-elixir`) and
none for the generated Go tree. Bazel builds Go bindings from the
`.proto` via `go_proto_library` and never reads the committed
`netprobe.pb.go`, so a proto edit without `make generate-proto` leaves
Bazel green while `go build` compiles a stale file. A `verify-proto-go`
mirror is not a trivial addition: the Elixir gate is reproducible because
its toolchain is pinned through mix, whereas `protoc` comes from the
system and would have to be pinned in CI first. Worth its own change
rather than a silent one here.

## S1. netprobe AF_PACKET capture engine

**Checkbox state was reset by the 2026-09-03 history rewrite and has been
re-derived from the code, not restored from memory.** What is ticked below was
verified present on staging.

**1.0 (pre-open) is DONE and now LIVE.** The descriptors are opened during the
privileged phase and the ordering is enforced by the type system:
`open_capture_handles` yields a `PreOpenedCaptures` token that
`drop_privileges` consumes, so a startup path that drops before opening does
not compile -- verified by writing that mistake and getting 2 compile errors.
Both branches in `main.rs` go through it; previously neither did, so the path
existed and never ran.

The packet path. No IPC surface yet -- provable on its own.

- [x] 1.1 Open an `AF_PACKET`/`SOCK_RAW` socket bound to the target
  ifindex with a TPACKET_V3 `PACKET_MMAP` ring, sized per session.
- [x] 1.2 Attach the session filter with `SO_ATTACH_FILTER` before the
  first frame can be queued, so no unfiltered packet is ever ringed.
- [x] 1.3 Write the tcpdump-subset to cBPF compiler for the UI/API
  string form: the grammar in `design.md` D2. Unsupported constructs
  return a structured error naming the construct. It MUST NOT widen a
  filter it did not fully understand.
- [x] 1.4 Accept a pre-compiled cBPF program (the RPCAP form) and attach
  it unchanged, bounding program length and refusing oversized programs
  before attach. The kernel validates the program on attach.
- [x] 1.5 Write the pcapng encoder: Section Header Block, one Interface
  Description Block per captured interface with `if_tsresol = 9`, then
  Enhanced Packet Blocks carrying the ring's `tp_sec`/`tp_nsec`. (22.4)
- [x] 1.6 Record frame direction from `PACKET_OUTGOING` so a session can
  request ingress, egress or both.
- [x] 1.7 `capture::session::CaptureSession` enforces `duration_s` and
  `byte_cap` and produces the terminal block's contents. Caps are checked
  BEFORE encoding, so a session never emits a block that carries it past a
  limit the operator set, and a cap that has already fired wins over a later
  `client_cancel` -- reporting the disconnect would misattribute why the
  capture stopped.

  The clock is a PARAMETER, not read inside: `offer` takes elapsed time. A
  duration cap tested against a real clock either sleeps for the cap (slow,
  and flaky under load -- this repo has a p99 test that fails at load average
  130) or shrinks the cap until the assertion proves nothing. Passing elapsed
  in makes "at the cap" and "one millisecond short" exact, and both are
  asserted.

  A closed session stays DRAINABLE rather than terminating instantly: frames
  the kernel already counted can sit in a partially filled block until
  `tp_retire_blk_tov`, so emitting the terminal block immediately truncates
  the capture with nothing erroring. `Termination.complete` cross-checks our
  own EPB count against the kernel's `tp_packets - tp_drops`; a mismatch is
  data loss neither counter shows alone.

  Tests verified to FAIL on mutation, not merely to pass: changing the
  duration comparison from `>=` to `>` breaks 2, and dropping the count
  cross-check breaks 1.
- [x] 1.8 Poll `PACKET_STATISTICS` for `tp_drops`; expose it as a
  netprobe metric and carry it in the terminal block. (`design.md` D7)
- [x] 1.9 Unit tests: the compiler accepts every documented form and
  rejects `tcp[13] & 2 != 0`, `vlan` and a bare typo with a named error;
  encoder output parses under an independent pcapng reader; both caps
  fire.
- [x] 1.10 Integration test on loopback: generate real ICMP, capture with
  `filter = "icmp"`, decode with an independent reader, assert the ICMP
  packets are present **and** that a non-matching flow on the same
  interface is absent. Both halves matter -- the second is what proves
  the filter does anything.
- [x] 1.11 Differential test: compile a set of filter strings with the
  compiler from 1.3 and assert the resulting cBPF selects the same
  packets as libpcap's own compilation of the same string, over a fixture
  pcap. This is the only real check that the subset means what tcpdump
  means.
- [x] 1.12 Ring-full behaviour verified on a real host, not simulated.
  A deliberately tiny ring (one 4 KiB block, two frames) under a 20k-datagram
  flood: `Stats { captured: 19, dropped: 79981, malformed: 0 }`, and
  `is_complete()` false. The assertion that matters is the completeness flag,
  not the drop count -- a small ring under load will always drop; the failure
  being guarded is dropping SILENTLY, which is what happens if anything else
  reads `PACKET_STATISTICS` and takes the drops out of the session's total.
- [x] 1.13 Capture cost measured on 192.168.1.62 (Ubuntu 24.04, kernel 6.8,
  16 cores) at load average 0.18, with the default ring geometry:

      frames=800000  elapsed=5.00s  pps=159,995  18.3 MiB/s
      cpu=1.42s (~28% of one core)  1.8 CPU-seconds per million packets
      Stats { captured: 800000, dropped: 0, malformed: 0 }

  Zero drops at 160k pps is the result that matters: the default geometry
  sustains that rate on loopback without loss, so the AF_XDP fast path
  considered in design.md D1 has no case to answer yet.

  Note on the frame count: a 200k-datagram flood yields 800k frames because
  loopback delivers each frame twice (PACKET_HOST and PACKET_OUTGOING) AND
  nothing listens on the target port, so each datagram also produces an ICMP
  port-unreachable. Real frames through the ring either way, but the 4x is
  not what it appears.

  Deliberately printed rather than asserted against a threshold: a pps or CPU
  bound hard-coded here would be one machine at one load, and this repository
  already has a p99 assertion that fails at load average 130 for reasons
  unrelated to the code under test.

## S2. netprobe capture session RPC

- [x] 2.1 Activated `StartRemoteCapture` on the netprobe IPC surface. The
  header comes back on the REQUEST's sequence number, so a client learns
  its request succeeded and gets the pcapng section header in one round
  trip; every later block is unsolicited at sequence 0. The capture runs
  on a dedicated OS thread, because the ring poll is a blocking syscall
  and running it on the async runtime would stall every other IPC client
  behind one quiet interface. (22.1)
- [x] 2.2 Validated against `capture_interfaces` via `validate_interface`,
  which rejects `any` and wildcards BEFORE consulting the allowlist -- so
  an operator who put `any` in the config still cannot capture on every
  interface at once. (22.2)
- [x] 2.3 Uncompilable filters rejected before the session starts, with
  the structured error from 1.3. A precompiled program is validated too:
  a `jt` of 300 is refused rather than truncated to 44 by an `as u8`,
  which would produce a valid program jumping somewhere the client never
  asked for. (22.3, corrected: no `pcap` crate)
- [x] 2.4 Concurrent-session cap of exactly 1 per instance, deliberately
  coarser than `CaptureHandles::take`'s per-interface exclusion. The
  refusal names the busy interface, because "try again" is not an
  operator action. (22.6)
- [x] 2.5 UDS disconnect frees the socket and ring. **Measured on a real
  host, on a SILENT interface** -- a teardown that only works when the
  next packet arrives is the bug, and a busy loopback hides it:
  **112 ms and 360 ms** across runs, against a 5 s budget. Bounded by the
  poll interval rather than by traffic.
- [x] 2.6 **CORRECTED while implementing.** The task's premise was wrong
  in both halves. Mode 0600 had NOT landed on this socket: it landed on
  the AddonService socket, and that file's own comment named this one as
  the gap. Measured, not inferred -- a test asserting 0600 against a
  freshly bound server printed `left: 493`, which is 0o755, the umask
  default. That is now fixed and pinned by a test.

  `SO_PEERCRED` is implemented but deliberately NOT an authorization
  check, and making it one would be theatre: the socket is 0600 owned by
  netprobe's runtime user, so the only uids that can reach it are that
  user and root, and root defeats a uid allowlist with one `setuid`
  before `connect`. It would reject nothing 0600 does not, while breaking
  a `sudo` dev loop invisibly. The credentials are recorded as EVIDENCE
  -- verified on a real host: `pid=4129609 uid=0 gid=0`. What actually
  stops a capture from outside the control plane is 2.7.
- [x] 2.7 An unattributed request is refused, and refused FIRST -- before
  the interface, the filter or the snaplen -- so a request that bypassed
  the control plane is rejected for that reason rather than for whichever
  other field also happens to be wrong. Whitespace does not count as
  attribution: `" "` would satisfy a bare emptiness check and produce an
  audit record that says nothing while looking attributed.
  (`design.md` D8.7)
- [x] 2.8 Session start and stop go to the journal with session id,
  actor, interface, snaplen, filter size and caps, plus a warning naming
  the drop count when a capture is incomplete -- which an operator
  reading the pcapng in Wireshark cannot otherwise see. Refusals are
  logged too, since a refusal is exactly the event worth seeing when
  someone is probing what this netprobe will capture. (`design.md` D8.6)
- [x] 2.9 Tests. Unit: 17 for request validation, 9 for the capture loop,
  8 for the session lifecycle, 4 over the real IPC socket. Live, on a
  Linux host with `CAP_NET_RAW`
  (`rust/netprobe/tests/live_capture_ipc.rs`, `manual` + `#[ignore]`
  because RBE executors have no `CAP_NET_RAW`): the stream is written to
  a file and read by **capinfos and tshark**, not by this crate's encoder
  in reverse -- 4 packets, every one `ip.proto == 1`, so the ICMP filter
  let nothing else through. The journal lines are asserted through a
  capturing logger rather than eyeballed, because a format string that
  drops the actor still compiles, still logs, and still reads correctly.

  Mutation-checked rather than assumed green: compiling against the wire
  snaplen instead of the resolved one breaks 1 test, dropping the
  session-id check breaks 1, removing the drain grace breaks 2, and
  draining after a cap breaks 2.

**Two bugs found by writing the tests, both silent in production.**

1. **A released capture descriptor could not be armed again.**
   `Ring::into_socket` unmapped the ring but never freed it, and
   `setsockopt(PACKET_VERSION)` refuses to run against a socket that
   still has one. The SECOND capture on an interface failed with a bare
   `EBUSY` from a call that has nothing obviously to do with rings, on a
   descriptor that had been handed back "cleanly" -- and since a
   descriptor is opened once while privileged and cannot be reopened,
   that interface was finished for the life of the process while the
   first capture looked perfect. `into_socket` now frees the ring with a
   zeroed `tpacket_req3`, after the `munmap` (the kernel refuses while it
   is still mapped), and `a_released_descriptor_can_be_armed_again`
   covers it end to end. The `EBUSY` message now names the cause.

2. **A failed ring activation leaked the concurrency slot.** `SlotClaim`
   was a marker with no `Drop`, and the slot was released only by
   `SessionGuard`, which is not created until activation succeeds. Every
   later capture would have been refused as "already running" against a
   session that never started.

## S3. Agent to agent-gateway transport

Modelled on the camera relay (`design.md` D4).

- [x] 3.1 **CORRECTED while implementing.** The task specified a
  SERVER-streaming RPC. That points the data the wrong way: the gateway is
  the gRPC server and the agent is the client ("communication flows UP only
  (agent to gateway); the gateway never connects back to agents"), so
  server-streaming would have had the gateway streaming pcapng to the agent.
  Client-streaming carries the bytes correctly but gives the server no
  channel to speak on until the client finishes, which cannot meet 3.6's
  1-second cancel -- a capture matching nothing produces no messages to
  piggyback on, and that is the session most likely to need stopping.

  What landed is `proto/remote_capture.proto`: a BIDIRECTIONAL
  `RemotePacketCaptureService.StreamCapture`, modelled on
  `DesktopMediaService.StreamDesktopMedia`, which already uses this shape for
  the same reasons. pcapng flows client to server; credit and cancellation
  flow server to client on their own channel. Spec delta corrected to match.
  (23.1, 27.1)
- [x] 3.2 Prove the RPC multiplexes onto the existing mTLS HTTP/2
  connection: assert no second TCP or TLS session is opened. The
  `GatewayClient` capture-client factory test asserts the generated service
  receives the exact managed `grpc.ClientConn`; the capture path contains no
  dial or TLS setup. (23.2)
- [x] 3.3 **CORRECTED while implementing**, in two ways. The file split:
  routing a block to its session and pumping a session onto the gateway
  are different concerns with different failure modes, so this landed as
  `capture_session.go` (the read-loop side) and `capture_forwarder.go`
  (the gateway side) rather than one `capture.go`. And the direction:
  "receive the gRPC stream" was written under 3.1's original
  server-streaming shape; with the corrected bidirectional RPC the agent
  is the gRPC CLIENT, so it OPENS the stream and receives credit and
  cancellation on it.

  What landed: `Client.StartCapture` registers the session BEFORE the
  `StartRemoteCapture` request goes out -- netprobe may begin streaming
  the moment it accepts, and a sink registered afterwards would lose that
  race and count real blocks as a version skew. `routeCaptureBlock` is
  deliberately NOT the `select`/`default: drop` shape every other arm of
  the read loop uses: a dropped fingerprint event is a missing
  observation, a dropped pcapng block is UNDETECTABLE corruption, so this
  arm applies backpressure for `CaptureBlockTimeout` and then ENDS the
  session rather than dropping. Block bytes are copied from the netprobe
  frame into `CaptureBlock` untouched; no hop re-encodes. (23.3)
- [x] 3.4 Add the gateway-side server and forwarder, mirroring
  `camera_media_server.ex` and `camera_media_forwarder.ex`: one
  `:rpc.call` into core-elx on session open with `:nodedown` retry, then
  stream to the returned ingress pid over ERTS.
- [x] 3.5 Byte accounting per session, emitted at `AccountingInterval`
  (1 Hz) while the session is ACTIVE and once more as the terminal
  message, which is the LAST client message on the stream -- so upstream
  learns why a capture ended even when it ended badly. Counters come from
  `len(block.bytes)` while streaming and are replaced by netprobe's own
  cumulative totals on the terminal block, so no hop parses pcapng to
  report `bytes_streamed`. `complete` is false whenever netprobe counted a
  ring drop: a capture missing packets must never present as a whole one.

  The cadence is driven by an injected clock, so the test asserts the
  exact number of heartbeats instead of sleeping and hoping. (23.4)
- [x] 3.6 Gateway cancellation, for the AGENT hop, within 1 s -- and see
  3.8 for the hop this does not cover.

  The gateway's channel is read on its own goroutine, so a `CaptureCancel`
  lands while the send loop is parked on credit or on a silent netprobe.
  Piggybacking it on the send path would have made cancellation latency a
  function of traffic volume, and a capture matching nothing -- which
  produces no traffic at all -- is exactly the session most likely to need
  stopping. That case is the test: no blocks are sent at all, and the
  measured cancel-to-terminal-state time is asserted under one second. The
  terminal `SessionStateChanged` goes out on the ORIGINAL context, not the
  cancelled one, because the point of a terminal frame is that it survives
  the thing that ended the session.

  **CORRECTED while implementing.** Credit is seeded at zero, NOT from
  `start.initial_credit_bytes`. The agent composes that message, so
  spending it would let the agent grant itself up to 4 GiB before the
  gateway had accepted the session -- the one thing a credit scheme exists
  to prevent. The gateway sends 0 inbound and grants for real in its first
  ack. A cancel that arrives while the send loop is waiting for credit
  therefore unwinds with `context.Canceled`, which is the cancel working
  and is reported as `CLIENT_CANCEL`, not as a transport fault. (23.5)
- [x] 3.7 Surface an active-capture indicator in the agent status
  response. The capability payload reports only `active` and `session_count`;
  it omits session IDs, filters, and actor data, and follows the netprobe
  client's registered-session lifecycle. (23.6)
- [ ] 3.8 **FOUND while implementing 3.6, and deliberately left open.**
  3.6 as written says cancellation reaches *netprobe*; the agent hop meets
  that budget, but the last hop does not exist yet. netprobe has NO
  in-band stop: `StartRemoteCapture` has no `Stop` counterpart, and
  `handle_connection` holds the session in a per-connection
  `Option<StartedSession>` whose `Drop` is the only cancel path
  (`rust/netprobe/src/server.rs`, `capture/service.rs`). So a capture on
  the host today ends when a cap fires or when the whole netprobe IPC
  connection closes -- and that connection is SHARED with fingerprint,
  DPI, flow-attribution and census delivery, so the agent cannot close it
  to stop one capture.

  Until this is closed, a cancelled session stops being forwarded while
  the ring on the captured host keeps filling to its duration or byte cap.
  For a surveillance capability that is the wrong direction to fail, so it
  is recorded here rather than hidden behind 3.6's checkmark. Closing it
  means either a `StopRemoteCapture` frame on the netprobe IPC surface
  (a netprobe add-on version bump, so its own slice) or a dedicated IPC
  connection per capture session, whose close netprobe already treats as a
  stop -- measured at 112 ms and 360 ms against a 5 s budget in 2.5.

## S4. core-elx ingress session, lifecycle and RBAC

Parallelizable with S1-S3. The audit and event surface built on top of
this resource is S5, which no front door ships without.

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
- [ ] 4.9 Test that a PaperTrail version exists for every transition and
  carries the full metadata set from 4.7. (24.12)
- [ ] 4.10 Test partition scoping: a request naming an agent in another
  partition is denied and creates no record in either. The audit half of
  that denial is S5.9.

## S5. Audit, security events and operator visibility

Depends on S4. No front door ships before this does. Reuses
`ServiceRadar.Events.AuditWriter`, `ServiceRadar.Security.SecurityEvent`
and `ServiceRadar.Security.AuditHistory` rather than inventing a pipeline.

- [ ] 5.1 Emit an audit event for every lifecycle transition --
  requested, authorized, started, stopped, completed, aborted, timed out,
  denied -- through `AuditWriter`, which persists OCSF Log Activity
  (`class_uid: 1008`) on `logs.internal.audit` and publishes a live copy
  on `live.logs.internal.audit`. The live copy is what makes suppression
  of a database row detectable rather than silent. (`design.md` D8.1-2)
- [ ] 5.2 Write the **authorization** event synchronously: if it cannot
  be recorded, the capture does not start. Later lifecycle events are
  written asynchronously and their failures increment an alertable
  counter rather than tearing down a running session. Do not add a bypass
  flag. (`design.md` D8.10)
- [ ] 5.3 Add `Serviceradar.Telemetry.RemotePacketCaptureSession` to the
  `AuditHistory` allow-list (`security/audit_history.ex:25-43`, alongside
  `ServiceRadar.Edge.ProxmoxConsoleSession`). Without this the resource is
  fully audited and completely invisible in Settings -> Audit -> History.
- [ ] 5.4 Test that a capture session **actually appears** in
  `AuditHistory.list_recent/2` for an actor with `agent_capture:audit_view`.
  Gate on the row being rendered, not on the audit write returning `:ok`.
- [ ] 5.5 Emit a `SecurityEvent` with severity on session start and stop,
  so capture appears on the Security dashboard and not only in an audit
  timeline someone has to go looking for. (`design.md` D8.4)
- [ ] 5.6 Emit a periodic `SecurityEvent` every 60 s while a session is
  active, so a long-running capture stays present in the feed rather than
  appearing only at its start. (`design.md` D8.8)
- [ ] 5.7 Emit audit events for capture-token mint and revoke, and for
  rpcap authentication success and failure with the source address.
- [ ] 5.8 Add counters for sessions started, sessions denied,
  authentication failures and audit-write failures, so anomalies are
  alertable without querying the database. (`design.md` D8.9)
- [ ] 5.9 Test that a denial creating no Ash resource still produces a
  durable audit event naming actor, partition and requested agent.
  (24.11)
- [ ] 5.10 Test that a blocked authorization write prevents the capture
  from starting -- the failure branch of 5.2, which is the one that
  proves no capture runs unrecorded.
- [ ] 5.11 Test that an actor with `agent_capture:audit_view` sees
  sessions started by other users in the same partition, and none from
  another partition. (`design.md` D8.5)

## S6. Opt-in retention

- [ ] 6.1 Add retention fields to the session resource mirroring
  `remote_access_recordings`: `storage_backend` (default
  `datasvc_object_store`), `storage_bucket`, `object_key`, `manifest`,
  `retention_expires_at`, byte counters. Payload bytes never go in a row.
- [ ] 6.2 Fan out in the ingress session: when a session is marked
  retained, write pcapng to the object store alongside streaming it to
  the client. Default is live-only.
- [ ] 6.3 Gate retention on `agent_capture:retain` and the partition
  retention policy; a request for retention without the permission is
  denied and audited.
- [ ] 6.4 Encrypt the manifest through AshCloak, as
  `20260518143000_encrypt_remote_access_recordings` does.
- [ ] 6.5 Add the retention expiry job; expired objects are deleted and
  the row records the deletion.
- [ ] 6.6 Tests: a retained session's object downloads and parses as
  pcapng; an unretained session leaves no object behind; an expired
  object is gone and the row says so.

## S7. `rpcaps://` listener -- the Wireshark front door

Depends on S5. Security posture is `design.md` D3; each refusal below is
a spec requirement, not an implementation detail.

- [ ] 7.1 Add the TCP acceptor on `ThousandIsland` (arrives with Bandit,
  `elixir/web-ng/mix.exs:157`). No raw-TCP listener exists in this
  codebase today, so TLS termination, connection limits and shutdown need
  their own tests.
- [ ] 7.2 Implement the RPCAP framing: `struct rpcap_header {ver, type,
  value, plen}` and the message set `FINDALLIF`, `OPEN`, `STARTCAP`,
  `UPDATEFILTER`, `CLOSE`, `PACKET`, `AUTH`, `STATS`, `ENDCAP`, with
  replies flagged `| 0x80`.
- [ ] 7.3 Require TLS: refuse to complete an unencrypted handshake.
  Plaintext `rpcap://` is rejected before authentication.
- [ ] 7.4 Refuse `RPCAP_RMTAUTH_NULL`. Anonymous capture is never
  permitted.
- [ ] 7.5 Add scoped capture tokens: minted in Settings, bound to one
  partition, carrying `agent_capture:remote`, with an expiry, revocable,
  shown once, stored hashed. `RPCAP_RMTAUTH_PWD` carries the token, never
  an account password.
- [ ] 7.6 Resolve the token to an actor and call the same
  `request_capture` action the UI calls. The listener holds no
  authorization logic of its own.
- [ ] 7.7 Scope `FINDALLIF` to the agents and allowlisted interfaces that
  actor may capture on. The natural implementation returns the whole
  fleet and leaks agent inventory.
- [ ] 7.8 Refuse `RPCAP_STARTCAPREQ_FLAG_DGRAM` and any separate data
  connection not bound to the authenticated session by a one-time token,
  including `RPCAP_STARTCAPREQ_FLAG_SERVEROPEN`.
- [ ] 7.9 Rate-limit and lock out authentication failures using
  `ServiceRadar.Security.RateLimiter` and `AuthLockout`; audit successes
  and failures with the source address (S5.7).
- [ ] 7.10 Translate pcapng Enhanced Packet Blocks to `RPCAP_MSG_PACKET`
  with `struct rpcap_pkthdr`, and answer `RPCAP_MSG_STATS_REQ` with the
  session's captured and dropped counts. Document that this path
  truncates nanosecond timestamps to microseconds -- a property of RPCAP.
- [ ] 7.11 Abort the session when the control connection drops.
- [ ] 7.12 Ship the listener disabled by default, with explicit bind
  configuration and documentation that exposing it requires provisioning
  a TCP load balancer or NodePort on purpose.
- [ ] 7.13 End-to-end test with stock Wireshark or `rpcapd`-compatible
  libpcap: capture succeeds over `rpcaps://`, and each of plaintext, NULL
  auth, UDP data and a wrong-partition agent is refused with the right
  error.

## S8. web-ng edge for the browser

- [ ] 8.1 Phoenix Channel endpoint dispatching to core-elx over ERTS RPC
  for RBAC, audit and session creation, then proxying pcapng bytes
  unchanged. (24.7)
- [ ] 8.2 WebSocket endpoint for the browser live view, sharing the same
  ingress session. This is the UI's transport; it is not a Wireshark
  transport, because Wireshark has no WebSocket capture input.
- [ ] 8.3 Client-disconnect detection: on client stream close, propagate
  over ERTS RPC so core-elx stops the agent session and transitions the
  record to `aborted`. (24.9)
- [ ] 8.4 Test: kill the client mid-stream, assert the agent-side session
  ends within 5 s and the record reaches `aborted`.

## S9. Web UI and agent registry

- [ ] 9.1 "Start Remote Capture" action on Agent Detail, and on Device
  Detail when the device is an agent host, guarded by
  `agent_capture:remote`. (26.1)
- [ ] 9.2 Request modal collecting interface, filter, `duration_s`,
  `snaplen`, `byte_cap` and retention; pre-fill allowlisted interfaces;
  reject values over the partition ceiling inline. (26.2)
- [ ] 9.3 Active-session card: session id, elapsed, bytes streamed,
  packets dropped, filter, Stop. (26.3)
- [ ] 9.4 Capture history behind `agent_capture:audit_view`, showing
  sessions started by any actor in the partition, with a download for
  retained sessions. (26.4)
- [ ] 9.5 Capture-token management in Settings: mint, list, revoke, with
  the token shown once.
- [ ] 9.6 Active-session indicator on the Agent Detail capability badge,
  so an agent under capture is visible without opening it. (26.5)
- [ ] 9.7 Add `remote-packet-capture` to the agent capability vocabulary;
  advertise `enabled` where available, `unavailable` otherwise. (27.2)
- [ ] 9.8 Surface active-session state on the agent registry record.
  (27.3)
- [ ] 9.9 Playwright: request modal, active-session card, history,
  token management, RBAC denial, and the audit timeline rendering a
  completed session.

## S10. End-to-end validation

- [ ] 10.1 A user with `agent_capture:remote` starts a capture from the
  Web UI on `--filter icmp`, and the streamed pcapng decodes with
  `tshark -r -` showing ICMP packets. (28.1)
- [ ] 10.2 The same capture driven from stock Wireshark over `rpcaps://`,
  selected from the Remote Interfaces dialog.
- [ ] 10.3 A user without the permission is denied on both front doors,
  and an audit record is written for each. (28.2)
- [ ] 10.4 Cap enforcement: duration overrun, byte overrun,
  concurrent-session collision. (28.3)
- [ ] 10.5 Mid-stream client disconnect on both front doors: the
  agent-side session ends within 5 s and the record reaches `aborted`.
  (28.4)
- [ ] 10.6 Auditability: start and stop a capture, then verify the
  Settings -> Audit -> History timeline renders AshPaperTrail-backed
  entries for request, start and stop with actor, partition, agent id,
  interfaces, filter metadata, byte count and termination reason, and
  that the Security dashboard shows the start and stop events. (28.5)
- [ ] 10.7 Verify the captured host's journal carries the session start
  and stop lines independently of the control plane's records.

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
- [x] 11.5 The `srctl` rename and `srctl capture` work is split out and
  tracked in GitHub [#4260](https://github.com/carverauto/serviceradar/issues/4260); it is excluded from this change's
  scope.
