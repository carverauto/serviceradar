# Change: Add Host Network Visibility Sidecar (`netprobe`)

## Why

Four operator-painful gaps share the same root cause — ServiceRadar
cannot observe what is happening on the wire on the host where the agent
runs:

1. **Devices that do not answer SNMP land in inventory as
   `type_id = 0` (Unknown).** Most BYOD endpoints, IoT, embedded
   appliances, and integration-imported devices (Armis, NetBox) have no
   OS or vendor evidence beyond what the importing system already
   supplied. Issue
   [#3423](https://forgejo/issues/3423) covers this gap and its
   accompanying PRD pins the implementation to passive p0f / JA4 / HTTP
   fingerprinting.
2. **NetFlow records are anonymous at the endpoint.** The existing
   `flow-collector` ingests sFlow / NetFlow from switches, but a record
   like `192.0.2.10:51234 → 198.51.100.5:443, 10 MB` does not tell an
   operator *which process on the source or destination host produced
   that flow*. Network engineers tracing flows for Cisco Secure
   Workload labelling and ACL design have no way to attribute observed
   bytes to a PID, command line, or unit, and currently resort to
   shipping `ss`/`netstat` snapshots or running side-channel scripts on
   every server.
3. **Operators repeatedly tap traffic and run Wireshark on-site.** Every
   time someone needs to classify an unknown protocol or characterise a
   stream for policy work, the same loop plays out — drive to the site,
   tap a port, fire up Wireshark, classify, leave. There is no
   continuous protocol-classification signal a control plane can query.
4. **Wireshark cannot reach edge / compartmentalised networks.** When a
   passive signal is not enough and an engineer needs full packet
   detail, the only path today is physical access (drive on-site, ssh
   over a VPN, tcpdump-and-scp, or stand up a temporary `rpcapd`
   listener). Every one of those workflows asks the operator to punch
   firewall holes or extract files from a network that was specifically
   built to keep both out. Meanwhile the agent itself already holds a
   hardened mTLS gRPC channel back to `agent-gateway` and on to
   `core-elx` / `web-ng`, and is precisely the kind of trusted reach
   that should be carrying engineer-driven capture instead.

All four share the same underlying capability surface: packet capture
on operator-chosen interfaces, optional protocol dissection, OS /
device fingerprinting, eBPF flow-to-process binding, and the ability to
*stream* selected captures back to authorised users on demand. Building
independent sidecars (or three Go subsystems) duplicates capture
surface, capability requirements, IPC, lifecycle management, and
operator UX. One sidecar plus one streaming-RPC surface — wrapped in
ServiceRadar's existing RBAC, audit, and mTLS transport — gives all
four use cases for the cost of one.

This change introduces a single Rust sidecar — `netprobe` — bundled with
`serviceradar-agent` and supervised by it, that provides all three
capabilities through one IPC contract, one capability bundle, one socket,
and one set of operator-facing profiles. It supersedes the earlier
`add-passive-device-fingerprinting` scope.

Rust was chosen because:

- `huginn-net` (TCP p0f, HTTP, TLS-JA4) is already a maintained Rust
  crate.
- The most mature host-level protocol-dissection + eBPF
  process-attribution reference implementation we found —
  [rustnet](https://github.com/domcyrus/rustnet) — is Rust, and its
  dissector set (HTTP, TLS SNI, DNS, SSH, FTP, QUIC, MQTT, BitTorrent,
  …) and its `aya`-based eBPF socket / PID correlation are cleanly
  reusable as **library-level patterns**, even though rustnet itself is
  shipped as a TUI binary.
- ServiceRadar already has a disciplined `rust/` workspace with several
  production sidecars (`trapd`, `flow-collector`, `bmp-collector`,
  `otel`, `rdp-adapter`) and the Bazel `rules_rust` toolchain to build
  them.
- Go's eBPF story (`cilium/ebpf`) is production-grade, but the DPI
  dissector ecosystem in Go is not comparable to what is cheaply
  cherry-pickable from rustnet.

`netprobe` will not depend on rustnet as a crate (it is structured as a
TUI binary, not a library). Instead this change extracts the patterns
ServiceRadar needs into `netprobe` directly, depending on the same
underlying crates rustnet itself uses — `huginn-net` for fingerprinting,
`aya` (preferred) or `libbpf-rs` for eBPF, and `etherparse` /
`pktparse-rs` for parsing.

The change also lands the first ServiceRadar agent component that
supervises a co-located native sidecar. The supervision pattern is
extracted into its own capability (`agent-sidecar-runtime`) so future
native co-processes can adopt it without re-implementing lifecycle
management.

## What Changes

### New capabilities

- **`host-network-visibility`** — defines the `netprobe` binary contract,
  the IPC protocol the agent uses to drive it, the four event streams it
  produces (fingerprint, DPI, local flow attribution, process snapshot),
  the unified `VisibilityProfile` model that scopes capture per-device
  via SRQL, capture-interface allowlists, eBPF capability requirements,
  privacy redaction at the IPC boundary, and the path by which signals
  feed inventory enrichment, flow attribution, and the existing
  discovery pipeline.
- **`agent-sidecar-runtime`** — defines how `serviceradar-agent`
  starts, supervises, restarts, and gracefully stops bundled native
  sidecars (`netprobe` first, others later): UDS lifecycle, health
  probes, restart back-off, circuit-breaker, structured logging
  passthrough, status surfacing.
- **`remote-packet-capture`** — defines on-demand engineer-driven
  capture sessions that stream pcapng over the existing
  `agent → agent-gateway → core-elx` mTLS transport. Covers the
  session model (request, authorisation, start, stream, stop,
  audit), per-session BPF filter and snaplen pushdown, max session
  duration and concurrent session caps, the streaming RPC contract,
  the `srctl capture` CLI helper that bridges to a local Wireshark,
  and the RBAC permission set (`agent_capture:remote`).

### New Rust component

- `rust/netprobe/` Cargo crate built as `serviceradar-netprobe`, added
  to the workspace `Cargo.toml` and exposed via `rust/netprobe/BUILD.bazel`
  (`rust_binary`) mirroring `rust/trapd/`.
- Static **musl** builds for `x86_64-unknown-linux-musl` and
  `aarch64-unknown-linux-musl`, registered in `MODULE.bazel`
  `extra_target_triples` and `.cargo/config.toml`.
- New Cargo dependencies pulled into the workspace via crate-universe:
  `huginn-net` (fingerprinting), `aya` + `aya-log` + `aya-ebpf`
  (eBPF), `etherparse` (parsing), `pcap` (capture handle), `tokio`
  (already present), `prost` (already present).

### Sidecar capabilities (`netprobe`)

- **Passive OS / device fingerprinting** — TCP p0f, TLS JA4/JA4S, HTTP
  signature analysis (via `huginn-net`).
- **Deep packet inspection** — per-flow protocol classification across
  HTTP/1.x, HTTP/2 cleartext, TLS SNI, DNS, SSH, FTP, QUIC, MQTT,
  BitTorrent at MVP; designed for additive dissectors over time.
- **Per-process flow attribution (eBPF)** — every locally-observable
  TCP, UDP, and QUIC socket lifecycle event is captured via eBPF
  (sock_ops / kprobes on `tcp_connect`, `inet_csk_accept`, `udp_sendmsg`,
  `udp_recvmsg`) and joined to `/proc` to produce `(5-tuple → PID,
  comm, cmdline, uid, container-id)` attribution.
- **NetFlow ↔ application attribution join** — the agent forwards
  external NetFlow records seen by `flow-collector` for the host's IPs to
  `netprobe`, which annotates them with local process attribution when
  the 5-tuple matches an observed local socket. Annotated flows are
  pushed back into the existing flow pipeline.
- **Process snapshot stream** — periodic snapshot of locally-bound
  listening sockets and their owning processes, so the agent can answer
  "what is listening here and what owns it" without packet observation.
- **On-demand pcapng capture sessions** — per-request, time-bounded
  packet capture with operator-supplied BPF filter and snaplen,
  emitting raw pcapng blocks (SHB + IDB + EPB) over a dedicated IPC
  stream that the agent forwards through `agent-gateway` and `core-elx`
  to the requesting client (typically `srctl capture` piping into
  `wireshark -k -i -`). Strictly opt-in per session, RBAC-gated,
  audit-logged, time- and byte-bounded.

### Remote-capture transport and user flow

The proposal reuses ServiceRadar's existing trust chain. Agents never
talk to `core-elx` directly — they only reach `agent-gateway` over the
existing mTLS gRPC control stream. The Erlang side
(`core-elx` ↔ `agent-gateway`) uses ERTS RPC (Erlang distribution); the
user-facing side (`serviceradar-cli` and the browser) talks to `web-ng`, which in
turn dispatches to `core-elx` over ERTS RPC.

```
[ Wireshark on laptop ]
        ^
        | stdin / pcapng pipe (local)
[ srctl capture ]
        |
        v  HTTPS streaming + device-code JWT
[ web-ng (Phoenix) ]
        |
        v  ERTS RPC
[ core-elx ] — RBAC, audit, session record, brokering only
        |
        v  ERTS RPC
[ agent-gateway ]
        |
        v  gRPC server-streaming over existing mTLS HTTP/2
[ serviceradar-agent ]
        |
        v  UDS (existing netprobe IPC)
[ netprobe ] — libpcap on allowlisted interface
```

`srctl` (the Go CLI at `go/cmd/cli/`, renamed from `serviceradar-cli`
as part of this proposal) is the user-side endpoint of the flow. It
is the workstation-installed ops/runtime CLI; the existing
`@carverauto/serviceradar-cli` npm binary remains in place but stays
scoped to dashboard SDK authoring. The rename is paired with porting
the RFC 8628 device-code client (currently only in the JS CLI) into
the Go binary so it can hit the same `add-cli-device-auth`
server-side endpoints. The existing `serviceradar-cli` invocation
(`enroll`, `user create`, …) is preserved as a backward-compatible
symlink for the lifetime of one release cycle, then deprecated.

The agent ↔ agent-gateway hop of the capture stream uses **gRPC
server streaming over the existing mTLS connection** — not a new
gRPC channel and not any non-gRPC transport. Specifically, the
pcapng frames ride a long-lived server-streamed RPC multiplexed
onto the same HTTP/2 connection that already carries the agent's
control stream and command bus (per `agent-connectivity`), so there
are no new sockets, no new ports, and no new TLS sessions to
provision.

End-to-end flow:

1. Engineer (one-time, per workstation) runs
   `srctl auth login --instance https://serviceradar.example.com`.
   The CLI opens the browser to the device-code approval page,
   user signs in + approves, CLI receives the long-lived Guardian
   JWT. This reuses the server-side endpoints landed by
   `add-cli-device-auth`; the client side of the device-code flow is
   ported from the JS CLI into the renamed Go binary as part of this
   proposal.
2. Engineer runs `srctl capture --agent <agent-id>
   --interface eth0 --filter "tcp port 443" --duration 30s
   --snaplen 4096`. The cached device-code JWT is sent as
   `Authorization: Bearer …` on the streaming HTTPS request to
   `web-ng`. Agents have no role in this auth; `srctl` is acting as
   a human user.
3. `web-ng` dispatches the request to `core-elx` over ERTS RPC.
   `core-elx` authorises via Ash policies
   (`agent_capture:remote` on the target agent's partition), creates
   the `RemotePacketCaptureSession` record, and writes the audit
   event. (If a future iteration decides no `core-elx`-side processing
   is needed, `web-ng` may dispatch directly to `agent-gateway` — see
   open question 11 in `design.md`.)
4. `core-elx` invokes the agent-gateway command bus over ERTS RPC.
   `agent-gateway` opens a **gRPC server-streaming RPC**
   (`StartRemoteCaptureSession`) to the target agent multiplexed onto
   the existing mTLS HTTP/2 connection (per `agent-connectivity`'s
   `Command bus for on-demand actions`).
5. Agent passes the request to `netprobe` over UDS via a new
   `CaptureSessions` RPC. `netprobe` enforces the capture-interface
   allowlist and the per-session caps, opens pcap, and streams pcapng
   blocks back.
6. pcapng bytes flow upstream through the same channels in reverse:
   netprobe → agent (UDS) → agent-gateway (gRPC server-streaming
   over the existing mTLS HTTP/2 connection) → core-elx (ERTS) →
   web-ng (HTTPS stream) → `srctl`.
7. `srctl` writes pcapng to stdout; the engineer's shell pipes it
   into `wireshark -k -i -` (or `tshark`, `mergecap`, …).

No new firewall holes, no extra ports, no `rpcapd` deployments, and
the agent's existing edge-network trust boundary is unchanged.

### Agent integration

- New sidecar lifecycle manager at `go/pkg/agent/sidecar/` supervises
  `netprobe` over a Unix domain socket and surfaces its health through
  agent status. Generic enough to host future native sidecars.
- New bridge package `go/pkg/agent/netprobe/` translates each event
  type into the appropriate ingestion path: fingerprint + DPI events
  → discovery / inventory enrichment; flow-attribution events →
  flow-collector enrichment; process snapshots → device-inventory
  process map.
- New gRPC + JSON sub-config `visibility_config` carried inside
  `AgentConfigResponse` (compatible with `add-streamed-agent-config`
  chunked delivery), bearing per-device profile bindings and capture
  parameters resolved by an Elixir-side compiler.

### Flow-collector integration

- `flow-collector` is extended to publish a per-host filter signal
  describing which 5-tuples a given agent's `netprobe` should expect to
  attribute (i.e. flows touching that agent's host IPs).
- The agent subscribes to its own host's slice, forwards the records to
  `netprobe`, and republishes the attributed records into the existing
  flow pipeline under a new `attributed_flow` event type.
- No NATS account changes; no new JetStream subjects beyond a single
  `flow.attributed.*` subject.

### Control-plane (Elixir / Ash) integration

- New Ash resource
  `Serviceradar.Inventory.VisibilityProfile`: `name`, `description`,
  `enabled`, `target_query` (SRQL), `priority`, plus per-capability
  toggle maps: `fingerprint {tcp, tls, http}`,
  `dpi {protocols: [...]}`, `flow_attribution {tcp, udp, quic}`,
  `process_snapshot_interval_s`, `sample_interval_ms`, `retention_days`,
  partition scoping, RBAC policies.
- New compiler
  `Serviceradar.AgentConfig.Compilers.VisibilityCompiler` resolves
  per-device bindings using the shared `SrqlTargetResolver`.
- Device records gain passive fingerprint evidence and per-process map
  in OCSF `os.passive_fingerprint`, `metadata.passive_fingerprint`,
  `metadata.local_processes` (with safe redaction).
- New OCSF Network-Activity-class records persisted for attributed
  flows in the existing flow pipeline; no new top-level table.

### Imported-device coverage (Armis, NetBox, UniFi)

- Imported devices receive passive fingerprint + DPI enrichment
  whenever their canonical IP appears on a `netprobe`-enabled capture
  interface, joined through the existing `IP Alias Resolution`. No
  active probing is introduced.

### Web UI (web-ng)

- New "Visibility Profiles" management page under `Settings → Discovery →
  Visibility Profiles`, mirroring Sysmon / SNMP profile pages: list with
  target counts, edit form with SRQL `target_query` builder,
  per-capability toggles, sample intervals.
- New "Network Visibility" panel on Device Detail: passive fingerprint
  evidence, observed protocols (DPI breakdown), top processes by bytes
  in/out, last observation timestamp.
- New "Process Listeners" tab on Device Detail when the device is also
  an agent host: live listing of listening sockets and their owning
  processes/cmdlines (subject to redaction policy).
- New "Attributed Flows" view on the existing Flows dashboard surfacing
  the `attributed_flow` records (PID / process / cmdline alongside the
  classic NetFlow fields).
- Agent Detail page surfaces the new `host-network-visibility`
  capability and `netprobe` sidecar status.

### Bazel and packaging

- `rust/netprobe/BUILD.bazel` (`rust_binary`, `cargo_build_script`
  for proto + eBPF object compilation).
- `MODULE.bazel`: add `x86_64-unknown-linux-musl` and
  `aarch64-unknown-linux-musl` to `rust.toolchain(extra_target_triples=...)`.
- `.cargo/config.toml`: musl linker entries.
- `build/packaging/agent/BUILD.bazel`, `build/packaging/packages.bzl`,
  and `docker/images/BUILD.bazel` add
  `//rust/netprobe:netprobe` into the agent `pkg_files` payload at
  `/usr/local/lib/serviceradar/bin/serviceradar-netprobe`.
- deb/rpm postinst grants the *sidecar binary* `CAP_BPF`, `CAP_PERFMON`
  (kernel ≥ 5.8) and reaffirms `CAP_NET_RAW` via file capabilities so
  the agent process does not need to be granted `CAP_BPF`.
- Helm values gain a `netprobe.enabled` toggle and capability adds for
  the container (when run in Kubernetes the sidecar still runs as a
  child of the agent process; `securityContext.capabilities.add` for
  the pod includes `BPF` and `PERFMON`).
- `.forgejo/workflows/main.yml` adds an explicit musl-static-build
  matrix entry for `//rust/netprobe:netprobe`.

### Operational

- `netprobe` enforces a **capture-interface allowlist with
  deny-by-default**: it refuses `any`, refuses pseudo-interfaces, and
  refuses any interface not explicitly listed in the
  `VisibilityAgentConfig`.
- Capability sequencing: the binary acquires `CAP_BPF` /
  `CAP_PERFMON` / `CAP_NET_RAW` at start, loads eBPF programs, opens
  pcap handles, then drops to a non-root UID.
- Strong privacy redaction at the IPC boundary: no packet payloads,
  no HTTP URIs, no DNS query names by default (only counts and
  destination IPs), no process environment variables, redacted
  command-line policy.

## Impact

### Affected specs

- **NEW** `host-network-visibility`
- **NEW** `agent-sidecar-runtime`
- **NEW** `remote-packet-capture`
- **MODIFIED** `network-discovery` — accepts passive-observation
  ingestion records carrying fingerprint and DPI evidence.
- **MODIFIED** `device-inventory` — extends OCSF storage to hold
  passive fingerprint and per-device local-process snapshots.
- **MODIFIED** `device-identity-reconciliation` — adds passive
  fingerprint as a weak identity signal; adds local-process identity
  to the convergence pipeline for agent-host devices.
- **MODIFIED** `agent-config` — `visibility_config` sub-config delivery
  alongside mapper/sysmon.
- **MODIFIED** `agent-configuration` — sidecar manager initialisation
  at agent startup; refresh semantics on push-config delivery.
- **MODIFIED** `agent-connectivity` — new streaming RPC for remote
  capture session lifecycle and pcapng transport over the existing
  mTLS control channel.
- **MODIFIED** `agent-registry` — `host-network-visibility` and
  `remote-packet-capture` capability advertisement; sidecar health and
  active-session surfacing.
- **MODIFIED** `build-web-ui` — Visibility Profile management UI,
  Network Visibility / Process Listeners / Attributed Flows surfaces,
  and a "Start Remote Capture" action with session-state display.
- **MODIFIED** `flow-collector` — per-host slice publication for
  netprobe attribution and re-publication of attributed flows.

### Affected code (key paths)

- New: `rust/netprobe/` (Cargo crate + BUILD.bazel + eBPF objects)
- New: `go/pkg/agent/sidecar/` (generic sidecar manager)
- New: `go/pkg/agent/netprobe/` (IPC client, event normalisation)
- New: `proto/agent/netprobe/v1/netprobe.proto`
- New: `elixir/serviceradar_core/lib/serviceradar/inventory/visibility_profile.ex`
- New: `elixir/serviceradar_core/lib/serviceradar/agent_config/compilers/visibility_compiler.ex`
- New: `elixir/web-ng/lib/serviceradar_web_ng_web/live/settings/visibility_profiles_live/`
- New: `elixir/web-ng/lib/serviceradar_web_ng_web/live/flows/attributed_flows_live/`
- Modified: `MODULE.bazel`, `.cargo/config.toml`, `Cargo.toml`
- Modified: `build/packaging/agent/BUILD.bazel`,
  `build/packaging/packages.bzl`, `docker/images/BUILD.bazel`,
  `helm/serviceradar/templates/agent.yaml`
- Modified: `proto/monitoring.proto` — `AgentConfigResponse` gains
  `visibility_config`.
- Modified: `go/cmd/agent/main.go`, `go/pkg/agent/server.go`,
  `go/pkg/agent/push_loop.go` — wire sidecar manager, capability
  advertisement, control stream extensions.
- Modified: `rust/flow-collector/` — per-host slice publish path.
- Modified: `elixir/serviceradar_core/lib/serviceradar/inventory/device.ex`
  — accept new map keys.
- Modified: `elixir/serviceradar_core/lib/serviceradar/identity/rbac/catalog.ex`
  — `visibility_profiles:*` permissions, `attributed_flows:read`.

### Coordination

- Supersedes the prior `add-passive-device-fingerprinting` proposal.
- Coordinates with `add-streamed-agent-config` so the
  `visibility_config` sub-config rides the chunked delivery path
  natively rather than being retrofitted.
- Orthogonal to `add-unifi-wifi-discovery-parity` (vendor-DB lookups);
  both feed enrichment via the existing rule matcher.
- Touches `improve-mapper-topology-fidelity` only via corroborating
  evidence for neighbour identity; no required ordering.
- Lives alongside `add-bmp-dual-path-observability` and
  `refactor-bmp-collector-to-arancini` — distinct domains, no overlap.

### Phasing

This proposal is intentionally large because it captures the end-state
architecture. Implementation lands in named phases, each one shippable
and reversible on its own:

- **Phase 1 — OS fingerprinting only (the first shipping increment).**
  `rust/netprobe/` skeleton with `huginn-net` integration; static musl
  builds wired into MODULE.bazel and agent packaging; sidecar runtime
  in `go/pkg/agent/sidecar/`; IPC v1 protobuf carrying only
  `ApplyConfig` / `Ping` / `FingerprintEvents` (other event channels
  reserved); `VisibilityProfile` Ash resource with only the
  `fingerprint` toggles wired; compiler integration; discovery
  ingestion of fingerprint events; OCSF `os.passive_fingerprint` +
  `metadata.passive_fingerprint` storage; minimal Visibility Profile
  list+edit UI (fingerprint section only); agent advertises
  `host-network-visibility = enabled` for fingerprint and
  `unavailable` for other surfaces. **This is the slice that closes
  Forgejo #3423.**
- **Phase 2 — DPI.** Add dissectors (HTTP/1, HTTP/2, TLS-SNI, DNS,
  SSH, FTP, QUIC, MQTT, BitTorrent), DPI event stream, device
  metadata DPI map, DPI UI panel.
- **Phase 3 — eBPF flow attribution + process snapshots.** Load eBPF
  programs, emit `FlowAttributionEvent` + `ProcessSnapshot`, render
  local-process map + Process Listeners tab. Degraded mode for
  kernels without modern BPF support.
- **Phase 4 — NetFlow ↔ application attribution.** `flow-collector`
  per-host slice publication, agent forwarding into `netprobe`,
  `attributed_flow` republish, Attributed Flows view.
- **Phase 5 — Remote pcapng capture sessions.** `CaptureSessions` IPC
  RPC, agent-side session bridge over the existing mTLS control
  stream, `core-elx` session lifecycle + audit, `srctl capture` CLI
  helper, "Start Remote Capture" action on Device / Agent Detail.
- **Phase 6 — Polish and hardening.** Capture interface allowlist UI,
  privacy opt-in toggles, runbook, Cisco Secure Workload labelling
  cookbook, Grafana dashboard.

Phase 1 must land first; later phases can re-order based on operator
demand. Phase 2 has no dependency on Phase 5, and vice versa.

### Non-goals

- No active probing (Nmap/Masscan replacement).
- No TLS interception or decryption.
- No HTTP URI/body capture, no DNS name capture by default.
- No replacement of SNMP, sysmon, mapper, or `flow-collector`.
- No multi-tenant sharing of fingerprint signatures or process maps.
- No long-term packet retention. Remote capture sessions are time-
  and byte-bounded; we never persist captures on the agent host
  beyond the lifetime of an active session, and we do not stage
  captures on `core-elx` storage by default.
- No native Wireshark integration plugin in this change — `serviceradar-cli
  capture` pipes pcapng to stdout for any standard pcapng reader
  (Wireshark, tshark, mergecap, …). A native Wireshark `extcap`
  shim is a follow-up.
- No Windows / macOS eBPF support — those platforms get the agent
  without `netprobe`.
- No on-demand capture *replay* against historical traffic — the
  sidecar does not buffer past traffic for retrospective requests.
