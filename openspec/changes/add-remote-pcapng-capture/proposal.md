# Change: Remote Packet Capture ("point Wireshark at ServiceRadar")

## Why

An operator debugging a host should be able to open Wireshark, pick a
ServiceRadar agent, and watch that host's wire traffic -- without SSHing
anywhere, without installing tcpdump on the box, and with every session
authorized and audited centrally.

Phase 5 of `add-host-network-visibility-sidecar` specified a piece of
this and was never built. What exists today is two zero-field placeholder
messages, `StartRemoteCapture` and `PcapngBlock`, at
`proto/agent/netprobe/v1/netprobe.proto:400-406`, reserved on purpose by
task 4.1 and defended from a cleanup pass by GitHub issue
[#4025](https://github.com/carverauto/serviceradar/issues/4025). Nothing
else: no `go/pkg/agent/netprobe/capture.go`, no capture front door, no
`RemotePacketCaptureSession` resource, no `agent_capture:remote`
permission.

This change builds the whole path. It is a separate proposal rather than
an edit to the sidecar change for two reasons: the end goal is larger
than Phase 5 described, and **three of Phase 5's written tasks rest on a
premise that is false in this repository.**

### The premise that does not hold

Phase 5 assumes libpcap. Task 22.3 says to "compile the libpcap-style BPF
filter via the `pcap` crate"; task 22.4 says to "open a dedicated pcap
handle for the session". **No shipped netprobe build has libpcap.** The
`pcap` dependency sits behind a cargo feature named `remote-capture`
(`rust/netprobe/Cargo.toml:67`) with `default = []`, and
`NETPROBE_FEATURES` in `rust/netprobe/BUILD.bazel:11-15` returns `[]` for
every platform including both musl targets, so Bazel always compiles the
stub that bails with "pcap capture backend is not enabled in this build".
The lookalike is worth naming so it is not mistaken for progress:
`rust/netprobe/src/capture.rs` is the *passive* allowlisted-interface
opener for fingerprinting and DPI, it is dead in every build, and it
touches neither placeholder message.

### What netprobe actually has, and what capture actually needs

netprobe has three live packet paths, none of them libpcap: **AF_XDP**
(`rust/netprobe/src/af_xdp.rs`, hand-rolled over raw mmap'd rings),
**TC ingress and egress** classifiers, and socket-lifecycle kprobes.

AF_XDP cannot serve remote capture, and the code already says why:
`ebpf_runtime.rs:702-712` refuses to attach the XDP redirect to the
host's default-route interface, because an XSKMAP redirect *consumes* the
frame and would black-hole host connectivity. It is also ingress-only and
permanently so -- `bpf_redirect_map` into an XSKMAP is verifier-rejected
from TC (`ebpf/src/lib.rs:560-566`).

The decisive constraint comes from the Wireshark end. Wireshark's native
remote-capture protocol, RPCAP, does not carry a filter string: it
carries a **compiled classic BPF program** (`struct rpcap_filter` plus an
array of `struct rpcap_filterbpf_insn {code, jt, jf, k}`, filter type
`RPCAP_UPDATEFILTER_BPF = 1`). Wireshark compiles the operator's filter
locally with its own libpcap and ships the bytecode. Any eBPF-based tap
would therefore have to interpret arbitrary cBPF inside an eBPF program
-- an unbounded interpreter loop, which is precisely what the verifier
rejects.

**`AF_PACKET` + `PACKET_MMAP` + `SO_ATTACH_FILTER` is the answer**, and it
is what libpcap itself does on Linux. It accepts Wireshark's cBPF
natively because it is the same mechanism; it captures both directions
(`PACKET_OUTGOING` for transmitted frames); it is a copy, so it diverts
nothing and is safe on the default-route interface; the TPACKET_V3 ring
header carries `tp_sec`/`tp_nsec` timestamps and honours snaplen; and
`PACKET_STATISTICS` reports `tp_drops`. It is plain syscalls through
`nix` and `libc`, both already dependencies -- no C library, no eBPF, no
verifier risk. netprobe is already provisioned for it:
`addons/netprobe/addon.yaml:39` grants `CAP_NET_RAW`, and
`serviceradar-netprobe.service:61-62` puts it in both
`AmbientCapabilities` and `CapabilityBoundingSet`, with a comment reading
"eBPF + AF_XDP + raw/packet sockets for capture."

## What Changes

* **netprobe captures via `AF_PACKET`/`PACKET_MMAP`**, with the session's
  filter attached as cBPF via `SO_ATTACH_FILTER`. Kernel-enforced,
  exactly tcpdump's semantics, filtered before the copy into the ring.
* **Two front doors, one enforcement mechanism.** Wireshark supplies cBPF
  over RPCAP and it is attached as-is. The Web UI supplies a filter
  string, which netprobe compiles to cBPF from a documented tcpdump
  subset. Both end at the same `SO_ATTACH_FILTER` call, so there
  is no second filter semantics to keep in sync.
* **A `rpcaps://` listener** so stock Wireshark can point at ServiceRadar
  with nothing installed: Manage Interfaces, Remote Interfaces, host and
  port. `FINDALLIF` enumerates the agents and allowlisted interfaces the
  authenticated user may capture on; `STARTCAP` opens a session through
  the same RBAC and audit path as every other front door. TLS is
  mandatory -- plaintext `rpcap://` is refused.
* **Transport follows the camera relay**, which already implements this
  exact chain: agent streams to the gateway over gRPC
  (`camera_media_server.ex`), the gateway stays "the edge-facing trust
  boundary" and does one `:rpc.call` into core-elx on session open
  (`camera_media_forwarder.ex`), core-elx allocates a supervised ingress
  session process and returns its pid (`camera_media_ingress.ex`), and
  every subsequent frame goes straight to that pid over ERTS. Capture
  reuses the shape, including its `:nodedown` retry and lease handling.
* **Retention is opt-in per session.** By default bytes stream through
  core-elx to the requesting client and are never persisted; only session
  metadata and the audit trail are stored. A requester holding the
  retention permission may mark a session retained, in which case the
  ingress session also writes the pcapng to `datasvc_object_store` under
  the partition's retention policy. This mirrors
  `remote_access_recordings`, whose migration states that it
  "intentionally does not store terminal input/output payloads" and keeps
  a manifest plus `storage_backend`/`object_key` pointer instead --
  correct here too, since a pcapng of a busy interface dwarfs a terminal
  recording.
* **`StartRemoteCapture` and `PcapngBlock` get real fields**, which is the
  outcome issue #4025 was filed to protect.
* **`NetprobeFrame` gets `reserved` discipline and CI gets a `buf
  breaking` gate** (issue
  [#4026](https://github.com/carverauto/serviceradar/issues/4026)) before
  any new oneof arm lands. `buf.yaml` declares `lint` only today and
  `make proto-lint` is `buf lint`, so a future field reusing a freed tag
  would be accepted silently and mis-decode against un-upgraded peers.
* **Capture is built on the assumption that it will be misused.** Every
  lifecycle transition -- requested, authorized, started, stopped,
  denied -- writes a durable audit event through the existing
  `ServiceRadar.Events.AuditWriter`, which persists OCSF Log Activity and
  publishes a live copy off-host so suppression of a stored row is
  detectable. Start and stop also raise severity-carrying security
  events, and a long session keeps announcing itself rather than being
  reported only at its start. The session resource is added to the
  `AuditHistory` allow-list, without which it would be fully audited and
  completely invisible in the operator timeline. The authorization event
  is written synchronously, so no capture ever runs unrecorded. And the
  captured host logs the session locally, so evidence survives even if
  the control plane's records do not.
* **The `srctl` CLI is out of scope.** Phase 5 bundled a Go CLI rename
  and an `srctl capture` subcommand into this work; neither is needed for
  the goal, since Wireshark and the Web UI are the front doors. Both are
  tracked in GitHub [#4260](https://github.com/carverauto/serviceradar/issues/4260).
* The rest of Phase 5 -- the `core-elx` session resource with RBAC and
  AshPaperTrail audit, the `web-ng` edge, the Web UI and E2E validation
  -- is built as specified, across the slices in `tasks.md`.

## Impact

* Affected specs: `remote-packet-capture` (new capability),
  `agent-connectivity` (new streaming RPC), `host-network-visibility` (the
  AF_PACKET tap and its accounting).
* Affected code: `rust/netprobe/src/` (capture session, cBPF compiler,
  pcapng encoder), `proto/agent/netprobe/v1/netprobe.proto` and both
  committed generated trees, the agent-gateway proto,
  `go/pkg/agent/netprobe/`, `go/cmd/cli/`, `elixir/serviceradar_core/`
  (Ash resource, migration, RBAC catalog),
  `elixir/serviceradar_agent_gateway/`, `elixir/serviceradar_core_elx/`
  (ingress session, object-store writer), `elixir/web-ng/` (rpcap
  listener, WebSocket live view, UI), `buf.yaml` and the proto CI gate.
* Operator-visible: a new invasive action behind permissions granted to
  nobody by default, and a new network listener that must be deliberately
  enabled and exposed.
* Not affected: AF_XDP, DPI, fingerprinting and flow attribution keep
  their current behaviour. This change adds a capture path beside them
  and modifies none of them.
