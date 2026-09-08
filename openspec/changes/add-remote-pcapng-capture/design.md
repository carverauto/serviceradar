# Design: Remote Packet Capture

## Context

The goal is that an operator opens Wireshark, picks a ServiceRadar agent,
and watches that host's traffic -- authorized and audited centrally, with
nothing installed on the target host and nothing installed in Wireshark.

Phase 5 of `add-host-network-visibility-sidecar` specified a narrower
version of this against libpcap, which no shipped netprobe build
contains. `proposal.md` records that evidence. This document records the
decisions that replace it, the constraints each inherits from code that
already exists, and the things that must be measured rather than assumed.

Everything cited here was read in the source tree or in libpcap's own
headers, not recalled.

## Decisions

### D1. The tap is `AF_PACKET`, not eBPF and not libpcap

**Decision.** Capture with `AF_PACKET` + `PACKET_MMAP` (TPACKET_V3), one
ring per session, with the session filter attached via
`SO_ATTACH_FILTER`. This is what libpcap itself does on Linux.

**Why not AF_XDP**, the existing tap that already carries frames to
userspace:

* It cannot run on the interface operators want to debug.
  `attach_xdp_program` (`ebpf_runtime.rs:702-712`) refuses the
  default-route interface, because the XSKMAP redirect consumes the frame
  and would black-hole host connectivity. The guard is correct and must
  not be relaxed.
* It is ingress-only, permanently: `bpf_redirect_map` into an XSKMAP is
  verifier-rejected from TC (`ebpf/src/lib.rs:560-566`). A capture showing
  the echo request and not the reply is worse than none, because it looks
  like an answer.
* `AfXdpPacket` (`af_xdp.rs:41-46`) carries no timestamp; pcapng Enhanced
  Packet Blocks require one.

**Why not a TC eBPF capture arm**, which was this design's first answer:
RPCAP delivers filters as compiled cBPF (D2), so an eBPF tap would have
to interpret arbitrary cBPF inside an eBPF program. That is an unbounded
interpreter loop and the verifier rejects it.

**Why not libpcap.** A C library in a static musl cross-compile for two
architectures, plus new third-party surface in the edge binary. The only
thing it buys over `AF_PACKET` is convenience wrappers around syscalls we
can call directly.

**What `AF_PACKET` gives, all of it needed here:** both directions
(transmitted frames arrive with `PACKET_OUTGOING`); a copy, so it diverts
nothing and is safe on the default-route interface; `tp_sec`/`tp_nsec`
timestamps in the TPACKET_V3 ring header; snaplen honoured by the
attached filter's return value; and drop accounting through
`PACKET_STATISTICS` (`tp_drops`). It is plain syscalls via `nix` and
`libc`, both already dependencies -- no C library, no eBPF, no verifier.

**Capability posture is already correct.** `addons/netprobe/addon.yaml:39`
grants `CAP_NET_RAW` and `serviceradar-netprobe.service:61-62` carries it
in both `AmbientCapabilities` and `CapabilityBoundingSet`, with the
comment "eBPF + AF_XDP + raw/packet sockets for capture." No capability
change is required.

**Consequence for existing paths: none.** AF_XDP, DPI, fingerprinting and
flow attribution are untouched. This adds a capture path beside them.

### D2. One filter mechanism, two front doors

RPCAP does not carry a filter string. It carries a compiled classic BPF
program: `struct rpcap_filter {filtertype, dummy, nitems}` followed by
`nitems` of `struct rpcap_filterbpf_insn {code, jt, jf, k}`, with
`RPCAP_UPDATEFILTER_BPF = 1`. Wireshark compiles the operator's filter
locally with its own libpcap and ships the bytecode.

**Decision.** cBPF is the single enforcement representation.

* **Wireshark path:** the instruction array is attached as-is via
  `SO_ATTACH_FILTER`. The kernel validates it on attach; a malformed
  program is rejected by the kernel, not by us. cBPF socket filters can
  only read packet bytes and return a length, so they are safe by
  construction.
* **UI/API path:** the operator supplies a string, which netprobe
  compiles to cBPF from a documented tcpdump subset -- `ip`, `ip6`, `tcp`,
  `udp`, `icmp`, `icmp6`, `arp`, `host <ip>`, `net <cidr>`, `port <n>`,
  `portrange <a>-<b>`, `src`/`dst`, `inbound`/`outbound`, and
  `and`/`or`/`not` over those terms. Constructs outside the subset are
  rejected with a structured error naming the construct.

The compiler must never widen a filter it did not fully understand. A
filter that cannot be represented exactly is rejected, never
approximated: a capture that silently returns more than was asked for is
a data-exfiltration surface, and one that silently returns less is this
repository's own "job reported success while writing nothing" failure
shape.

Because both doors end at the same `SO_ATTACH_FILTER` call, there is no
second filter semantics to keep in sync, and the string compiler is a
convenience rather than a correctness surface.

**Program length is bounded** and oversized programs are refused before
attach, so a client cannot push an arbitrarily large filter.

### D3. Securing the rpcap listener

RPCAP's own security posture is weak: it permits `RPCAP_RMTAUTH_NULL`
(anonymous), its `RPCAP_RMTAUTH_PWD` sends username and password in the
clear unless TLS is in use -- libpcap's documentation says so in those
words -- and it can move packet data onto a separate UDP socket outside
any tunnel. The listener is therefore defined mostly by what it refuses.

1. **`rpcaps://` only.** The listener never completes an unencrypted
   handshake; plaintext is rejected before authentication.
2. **`RPCAP_RMTAUTH_NULL` refused.** Anonymous capture is never
   permitted.
3. **The password field carries a scoped capture token, never an account
   password.** Minted in Settings, bound to one partition, carrying
   `agent_capture:remote`, with an expiry, revocable, shown once, stored
   hashed. Wireshark's remote-interface dialog is a third-party credential
   field that may persist what is typed into it; an SSO password must
   never go there.
4. **The listener holds no authorization logic.** It resolves the token to
   an actor and calls the same `request_capture` Ash action the CLI and UI
   call -- one RBAC path, one set of ceilings, one PaperTrail, one
   denial-audit path. This mirrors the camera relay, where the gateway is
   "the edge-facing trust boundary" and core-elx is authoritative.
5. **`FINDALLIF` is an authorization surface.** It returns only the agents
   and allowlisted interfaces that actor may capture on. The natural
   implementation returns the whole fleet and would leak agent inventory
   and interface names to anyone who authenticates at all.
6. **The UDP data channel is refused.**
   `RPCAP_STARTCAPREQ_FLAG_DGRAM` / `PCAP_OPENFLAG_DATATX_UDP` would carry
   packet data outside the TLS tunnel, unauthenticated and in the clear.
   Any separate data connection, including
   `RPCAP_STARTCAPREQ_FLAG_SERVEROPEN`, must be bound to the
   authenticated session by a one-time token or refused.
7. **Authentication failures are rate-limited and locked out**, reusing
   the `RateLimiter` shipped by `add-cli-device-auth`; successful and
   failed authentications are audited with the source address.
8. **Off by default and deliberate to expose.** rpcap is raw TCP and
   cannot traverse the HTTP ingress, so reaching it requires provisioning
   a TCP load balancer or NodePort on purpose.
9. **Control-connection drop aborts the session**, identically to the CLI
   disconnect path. No capture outlives the client that requested it.

**Implementation note.** There is no raw-TCP listener in this codebase
today. `ThousandIsland` arrives transitively with Bandit
(`elixir/web-ng/mix.exs:157`) and is the acceptor pool to build on. Being
first means the TLS termination, connection limits and shutdown
behaviour need explicit tests rather than inherited ones.

### D4. Transport follows the camera relay

The chain agent to gateway to core-elx already exists for camera media
and should not be reinvented:

* `serviceradar_agent_gateway/camera_media_server.ex` terminates the
  agent's gRPC stream at the gateway, "the edge-facing trust boundary".
* `camera_media_forwarder.ex` does one `:rpc.call` into core-elx on
  session open, with `:nodedown` retry and explicit core-node resolution.
* `serviceradar_core_elx/camera_media_ingress.ex` allocates a session
  through a tracker, starts a supervised ingress process, and returns its
  pid; every subsequent chunk targets that pid directly over ERTS rather
  than paying another RPC hop.

**Decision.** Capture mirrors this: a `RemotePacketCapture` gRPC service
at the gateway, a forwarder that opens the session by RPC and then
streams to the returned pid, and a supervised ingress session in core-elx
that owns fan-out, byte accounting and termination.

### D5. Retention is opt-in, and payloads do not live in the database

`remote_access_recordings` is the precedent and it is explicit: its
migration says the table "intentionally does not store terminal
input/output payloads", keeping a manifest, retention window, byte
counters and a `storage_backend` / `storage_bucket` / `object_key`
pointer, with the manifest encrypted through AshCloak. The default
backend is `datasvc_object_store`.

**Decision.** Default is live-only: bytes stream through the ingress
session to the requesting client and are never persisted; only session
metadata and the audit trail are stored. A requester holding the
retention permission may mark a session retained, in which case the
ingress session fans out to `datasvc_object_store` under the partition's
retention policy, recording a manifest and pointer in CNPG `platform`.
A pcapng of a busy interface dwarfs a terminal recording, so payload
bytes never go in a row.

### D6. Timestamps and pcapng

TPACKET_V3 gives `tp_sec`/`tp_nsec` per frame, already wall-clock -- so
the monotonic-to-wall conversion the eBPF paths need
(`wall_nanos_from_monotonic`, `census.rs:367`) does **not** apply here.
Enhanced Packet Blocks carry those timestamps directly, and Interface
Description Blocks declare `if_tsresol = 9` rather than accepting the
microsecond default.

The rpcap front door is lossier by protocol: `struct rpcap_pkthdr` carries
`timestamp_sec` and `timestamp_usec`, so nanosecond resolution is
truncated to microseconds on that path only. The Web UI's WebSocket
path keeps full resolution. This is a property of RPCAP and must be
documented, not worked around.

### D7. Drops are counted, never silent

`PACKET_STATISTICS` reports `tp_drops` for the ring.

**Decision.** Poll it, surface it as a netprobe metric, carry a
per-session dropped count in the terminal `PcapngBlock`, and show it in
the session record and the UI. A session that dropped packets must not
present as a complete capture. On the rpcap path the same count is
returned through `RPCAP_MSG_STATS_REQ`, which Wireshark already surfaces.

### D8. Assume this will be misused, and make that visible

Remote packet capture is a surveillance capability. The design premise is
not that it will be attacked, but that it will eventually be pointed at
the wrong target by someone holding valid credentials. Controls must make
that **visible**, not merely recorded.

The infrastructure exists and is reused rather than reinvented:
`ServiceRadar.Events.AuditWriter` persists OCSF Log Activity
(`class_uid: 1008`) on `logs.internal.audit` with a live NATS copy on
`live.logs.internal.audit`; `ServiceRadar.Security.SecurityEvent` carries
severity into the Security dashboard;
`ServiceRadar.Security.AuditHistory` merges AshPaperTrail versions into
the Settings -> Audit -> History timeline; and
`ServiceRadar.Security.{AuthLockout, RateLimiter}` already handle
authentication abuse.

**Decisions:**

1. **Every lifecycle transition emits an audit event, not only a
   PaperTrail row** -- requested, authorized, started, stopped, completed,
   aborted, timed out, denied -- plus capture-token mint and revoke, and
   rpcap authentication success and failure.
2. **A PaperTrail row alone is not enough, because it is a database
   row.** An actor with database access could suppress it and the UI would
   show nothing. The live NATS copy leaves the trust boundary as the event
   is written, which is what makes suppression detectable rather than
   silent.
3. **The resource MUST be added to the `AuditHistory` allow-list**
   (`security/audit_history.ex:25-43`). It is not automatic: a resource
   absent from that list is fully audited and completely invisible in
   Settings -> Audit -> History. `ServiceRadar.Edge.ProxmoxConsoleSession`,
   the closest analogue, is already there. The acceptance test asserts a
   capture session actually appears in `AuditHistory.list_recent/2` --
   gating on the artefact, not on the write having returned `:ok`.
4. **Start and stop also emit a `SecurityEvent` with severity**, so
   capture appears on the Security dashboard rather than only in an audit
   timeline an operator has to go looking for. Starting a packet capture
   is a security event, not a configuration change.
5. **Active sessions are visible to owners and admins regardless of who
   started them.** A capture must never be visible only to its initiator;
   `agent_capture:audit_view` sees every session in the partition.
6. **The captured host announces itself locally.** netprobe logs session
   start and stop to the journal with session id, actor, interface and
   filter. If the control plane is compromised or its records are altered,
   evidence still exists on the host that was captured. This is the one
   control that survives an attacker who owns core.
7. **netprobe refuses an unattributed capture.** A request arriving
   without a core-issued session id and actor is refused, so a capture
   cannot be started by anything that bypassed the control plane -- including
   something local to the host holding the UDS.
8. **A long capture keeps announcing itself.** The 1 Hz
   `SessionStateChanged` exists for byte accounting; a coarser periodic
   security event (every 60 s) keeps a long-running session present in the
   feed rather than visible only at its start.
9. **Counters exist so anomalies are alertable**: sessions started,
   denied, authentication failures, and audit-write failures. A spike in
   denials or a capture outside normal hours should be something an
   operator can alert on without querying the database.
10. **Audit must not become a bypass.** This repository's own guidance is
    that "an audit that can reject a write grows a bypass flag, and the
    bypass becomes the default". The resolution here is asymmetric: the
    **authorization** event is written synchronously and a failure to
    write it fails the request, so no capture ever runs unrecorded;
    subsequent lifecycle events are written asynchronously and their
    failures increment an alertable counter rather than tearing down a
    running session.

## Slice boundaries

Each slice is one PR with acceptance that can fail.

| slice | scope | acceptance that can fail |
|---|---|---|
| S0 | proto fields, `reserved`, `buf breaking` gate, regenerate both trees | gate rejects a deliberately reused tag; `make verify-proto-elixir` clean |
| S1 | AF_PACKET capture engine, cBPF string compiler, pcapng encoder, caps | loopback ICMP capture decoded by an independent reader, with a non-matching flow proven absent |
| S2 | activate `CaptureSessions`, allowlist, 1-session cap, UDS teardown, `SO_PEERCRED`, edge-local logging | unattributed request refused; teardown under 5 s; journal carries session start and stop |
| S3 | `RemotePacketCapture` gRPC + gateway forwarder, modelled on the camera relay | asserts no second TCP/TLS session; cancel propagates under 1 s |
| S4 | core-elx ingress session, Ash resource, RBAC, policies, ceilings | partition-scope denial; atomic actions |
| S5 | audit events, security events, `AuditHistory` allow-list, counters | a session actually appears in `AuditHistory.list_recent/2`; a denial with no resource still writes an event; a blocked authorization write prevents the capture |
| S6 | opt-in retention to the object store, manifest, expiry | retained session downloads and parses; unretained leaves no object |
| S7 | `rpcaps://` listener, capture tokens, `FINDALLIF` scoping | stock Wireshark captures end to end; plaintext, NULL auth and UDP data each refused |
| S8 | web-ng edge: Phoenix Channel and the browser WebSocket | client-kill test: agent session dies within 5 s, state `aborted` |
| S9 | Web UI, capture-token management, registry capability | Playwright including the RBAC denial path |
| S10 | E2E | Wireshark over `rpcaps://` sees the ICMP; audit feed renders the session |

S4 depends on none of S1-S3 and can run in parallel. S5 depends on S4;
S7 depends on S5, because a front door must not exist before the audit
trail behind it does. S0 blocks everything. A twelfth slice, S11 in
`tasks.md`, is documentation-only supersession bookkeeping and carries no
code.

## Risks

* **The rpcap listener is a new network attack surface**, speaking a
  legacy binary protocol on a raw TCP port. D3 is the mitigation and its
  refusals are spec requirements, not implementation details. It is off
  by default.
* **First raw-TCP listener in the codebase.** No inherited test patterns
  for TLS termination, connection limits or shutdown.
* **AF_PACKET copy cost on a busy NIC.** Mitigated by kernel-side
  filtering and snaplen; measured in S1 rather than argued about.
* **An invasive action over the netprobe UDS.** Sidecar task 3.2 is HALF
  DONE: mode 0600 landed, `SO_PEERCRED` never did, which makes file
  permissions the entire authorization story for a socket that can now
  start packet captures. `SO_PEERCRED` lands in S2.
* **Two unarchived changes describing one capability.** Resolved by this
  change owning the corrected `remote-packet-capture` delta and the
  sidecar change's Phase 5 sections carrying a supersession annotation.

## Out of scope: the `srctl` CLI

Phase 5 bundled a Go CLI rename (`serviceradar-cli` to `srctl`) and an
`srctl capture` subcommand into this work. Both are **out of scope here**
and tracked separately.

Nothing in the end goal needs them. Stock Wireshark reaches capture over
`rpcaps://` (D3) and the Web UI covers the browser workflow; a CLI pipe
is a third front door for an audience already served. The rename is
independent of capture, touches packaging and five documentation pages,
and coupling a user-visible rename to a new feature makes both harder to
review and to roll back. Tracked in GitHub issue
[#4260](https://github.com/carverauto/serviceradar/issues/4260).

The filter-string compiler in D2 stays, because the Web UI's request form
takes a filter string. It is motivated by the UI, not by a CLI.
