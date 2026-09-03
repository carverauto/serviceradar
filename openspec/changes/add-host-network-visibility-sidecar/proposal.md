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
   [#3423](https://forgejo/issues/3423) covers this gap. ServiceRadar's
   answer is a **license-audited multi-corpus fingerprint ensemble**
   (see D14 + D15): the p0f canonical TCP fingerprint computed inside
   the eBPF kprobe as the foundation, backed by the upstream LGPL-2.1
   p0f corpus shipped as a separate replaceable data file, supplemented by
   five separately licensed additions — MuonFP (Censys, MIT) as a
   parallel TCP signature; Recog (Rapid7, BSD-2-Clause-Views) for
   HTTP / SSH / SMB / FTP / Telnet / SNMP / SIP / RDP / DNS banner
   fingerprints; Satori multi-protocol fingerprint XML (GPLv2, shipped
   as a separate replaceable data corpus with notices preserved) for
   TCP / DHCP / DNS / SMB / SSH / SSL / HTTP / browser / ICMP / NTP /
   SIP signatures; JA4 base (BSD-3, FoxIO patent-disclaimed) for TLS
   ClientHello; and HASSH (BSD-3) for SSH KEXINIT. Combined corpus
   audited reach: ~7,000 fingerprints across ~8 independent observation
   axes, vs huginn-net's p0f-only ~400. The `huginn-net` crate is
   dropped from the dependency set. The encumbered parts of FoxIO's
   JA4+ family (JA4T, JA4H, JA4S, JA4SSH, JA4X) are explicitly *not*
   used — their FoxIO License 1.1 terms and patent-pending posture
   are incompatible with ServiceRadar's commercial sale. Computing
   p0f canonical form in-kernel is genuinely ahead of the current
   commercial state of the art for passive OS fingerprinting; the
   multi-corpus ensemble on top of it pushes accuracy further by
   layering independent observation axes.
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

Closing the inventory-discovery gap further, the change also adds an
**active banner-grab phase** to the existing sweep service
(`go/pkg/scan/`, where the lightning-fast SYN half-open scanner
already lives). Sweep finds live `(host, port)` pairs today but
captures no application-layer evidence; the new phase, opt-in per
`SweepProfile`, completes a 3-way handshake against confirmed-live
targets and forwards the captured banner to netprobe via a new
`MatchBanner` IPC method so the §32 Recog corpus does the matching.
This pairs the lightning-fast reachability scan with on-demand
application-layer fingerprinting without duplicating the corpus or
adding cross-language regex codegen — see D16 for details.

This change introduces a single Rust sidecar — `netprobe` — bundled with
`serviceradar-agent` and supervised by it, that provides all three
capabilities through one IPC contract, one capability bundle, one socket,
and one set of operator-facing profiles. It supersedes the earlier
`add-passive-device-fingerprinting` scope.

Rust was chosen because:

- `aya` is the pure-Rust eBPF runtime that lets the same workspace own
  both the kernel-side programs (`#![no_std]`) and the userspace loader
  / classifier without a C toolchain at build time. JA4T canonical-form
  encoding inside the SYN kprobe is feasible because `aya-ebpf` permits
  a small `no_std` JA4T encoder, callable directly from the probe body.
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
ServiceRadar needs into `netprobe` directly. The original Phase 1 plan
pinned passive fingerprinting to the `huginn-net` crate (p0f-style TCP
analysis + JA4/JA4S extraction); the amendment in D14 replaces that
with a self-contained **license-clean fingerprint stack**: the p0f
canonical TCP fingerprint computed inside the eBPF SYN kprobe (primary
classifier, upstream LGPL-2.1 corpus kept as a separate replaceable file
plus ServiceRadar curated additions),
plus JA4 base (BSD-3, TLS ClientHello) and HASSH (BSD-3 via Corelight's
maintained fork, SSH KEXINIT)
encoded in userspace as confidence boosters when the corresponding DPI
dissectors fire. `huginn-net` is removed entirely. `aya` is the eBPF
runtime; `etherparse` / `pktparse-rs` handle userspace L3/L4 framing
for the DPI dissector path.

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
  AshPaperTrail-backed audit), per-session BPF filter and snaplen
  pushdown, max session duration and concurrent session caps, the
  streaming RPC contract, the `srctl capture` CLI helper that bridges
  to a local Wireshark, and the RBAC permission set
  (`agent_capture:remote`).

### New Rust component

- `rust/netprobe/` Cargo crate built as `serviceradar-netprobe`, added
  to the workspace `Cargo.toml` and exposed via `rust/netprobe/BUILD.bazel`
  (`rust_binary`) mirroring `rust/trapd/`.
- Static **musl** build targets for `x86_64-unknown-linux-musl` and
  `aarch64-unknown-linux-musl`, registered in `MODULE.bazel`
  `extra_target_triples` and `.cargo/config.toml`. Phase 1 / Phase 2
  shipping packages use the libpcap-enabled dynamic Linux build as a
  documented stopgap; Phase 3 replaces the continuous capture path
  with kernel-side eBPF + AF_XDP and removes the libpcap dependency
  from the continuous code path entirely. After the Phase 3 cutover,
  libpcap remains only for the Phase 5 remote-capture tunnel behind a
  `remote-capture` Cargo feature, declared as `Recommends` (not
  `Depends`) in deb/rpm metadata.
- Cargo dependencies pulled into the workspace via crate-universe:
  `aya` + `aya-log` + `aya-ebpf` (eBPF runtime and program crate),
  AF_XDP bindings (e.g. `xsk-rs` or `aya::maps::xdp`), `tokio`
  (already present), and `prost` (already present). `huginn-net` is
  explicitly removed; fingerprinting is handled by ServiceRadar-owned
  p0f / JA4-base / HASSH code. The `pcap` crate is gated behind the
  `remote-capture` Cargo feature; **continuous packet observation does
  not depend on libpcap at runtime after Phase 3**.

### Continuous capture is eBPF-only (revised 2026-05-27)

After Phase 3 cutover, continuous packet observation runs entirely in
the kernel:

- **TC ingress + egress eBPF programs** attached to each allowlisted
  interface. The TC programs parse the 5-tuple, look up a kernel BPF
  `flow_table` map, and:
  - For already-classified flows: bump byte/packet counters in-kernel
    and return `TC_ACT_OK`. **These packets never enter userspace.**
  - For new or in-classification flows: redirect the first 8–32
    packets to an AF_XDP ring for userspace dissection. Once
    classified, userspace writes the result back to the map and
    subsequent packets short-circuit in the kernel.
- **SYN-time fingerprinting via kprobe.** A `kprobe` on
  `tcp_rcv_state_process` (or the kernel-version-appropriate
  equivalent) extracts the SYN's TCP options at connection setup,
  emits one p0f-signature event per new connection, and userspace runs
  the in-tree p0f matcher / OS-match ensemble exactly once per
  connection rather than per packet.
- **Socket lifecycle + process attribution** via kprobes on
  `tcp_connect`, `inet_csk_accept`, `tcp_close`, `udp_sendmsg`,
  `udp_recvmsg`. Populates `flow_to_pid` and `process_info` BPF maps
  that the userspace classifier joins against to label each flow
  with its owning process.
- **No `degraded` half-state.** If any required eBPF program fails to
  load (kernel too old, verifier rejection, missing CAP_BPF), the
  sidecar refuses to start its continuous capture worker and the
  agent advertises `host-network-visibility = unavailable`. Hard
  kernel floor: 5.8.

The eBPF object code lives under `rust/netprobe/ebpf/` as a separate
Cargo crate compiled to BPF bytecode via `aya-ebpf` and embedded into
the userspace binary at build time. Maps are pinned under
`/sys/fs/bpf/serviceradar/netprobe/` so sidecar restart reattaches to
in-flight state without losing accumulated counters.

This is the architectural baseline that Datadog NPM, Cilium/Hubble,
and current-generation Cisco Secure Workload all converged on — for
the same reason ServiceRadar is making this commitment: per-packet
kernel→user transitions in libpcap-based userspace agents are the CPU
bottleneck that gates fleet-wide deployment. We avoid that trap from
day one (well, from Phase 3 onward; Phase 1/2 ship the libpcap
stopgap and Phase 3 deletes it rather than optimizing it further).

### Sidecar capabilities (`netprobe`)

- **Passive OS / device fingerprinting** — ServiceRadar-owned TCP p0f,
  JA4-base TLS ClientHello, and HASSH SSH KEXINIT analysis.
- **Deep packet inspection** — per-flow protocol classification across
  HTTP/1.x, HTTP/2 cleartext, TLS SNI, DNS, SSH, FTP, QUIC, MQTT,
  BitTorrent at MVP; designed for additive dissectors over time.
- **Per-process flow attribution (eBPF)** — every locally-observable
  TCP, UDP, and QUIC socket lifecycle event is captured via eBPF
  (sock_ops / kprobes on `tcp_connect`, `inet_csk_accept`, `udp_sendmsg`,
  `udp_recvmsg`) and joined to `/proc` to produce `(5-tuple → PID,
  comm, cmdline, uid, container-id)` attribution.
- **NetFlow to application attribution join** — netprobe sends local
  socket/process observations agent-up for bounded core persistence. Core
  correlates those observations with independently ingested NetFlow/IPFIX and
  stamps matching OCSF rows as `attributed_flow`; NetFlow is not replayed down
  to the agent or netprobe.
- **Process snapshot stream** — periodic snapshot of locally-bound
  listening sockets and their owning processes, so the agent can answer
  "what is listening here and what owns it" without packet observation.
- **On-demand pcapng capture sessions** — per-request, time-bounded
  packet capture with operator-supplied BPF filter and snaplen,
  emitting raw pcapng blocks (SHB + IDB + EPB) over a dedicated IPC
  stream that the agent forwards through `agent-gateway` and `core-elx`
  to the requesting client (typically `srctl capture` piping into
  `wireshark -k -i -`). Strictly opt-in per session, RBAC-gated,
  AshPaperTrail-audited, time- and byte-bounded.

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
   the `RemotePacketCaptureSession` record, and writes the audit trail
   through AshPaperTrail-backed Ash changes. (If a future iteration
   decides no `core-elx`-side processing
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
  → discovery / inventory enrichment; flow-attribution events → a
  retained `FlowAttributionEventBatch` on the dedicated agent status path;
  process snapshots → device-inventory process map.
- New gRPC + JSON sub-config `visibility_config` carried inside
  `AgentConfigResponse` (compatible with `add-streamed-agent-config`
  chunked delivery), bearing per-device profile bindings and capture
  parameters resolved by an Elixir-side compiler.

### Flow-attribution integration

- `serviceradar-agent` batches netprobe's local socket/process observations as
  `FlowAttributionEventBatch` and sends them through its ordered retained
  `StreamStatus` path to the authenticated agent-gateway/core boundary.
- Core derives the agent and partition from the authenticated status context
  and upserts the observations into
  `platform.flow_process_attribution_current`.
- `ServiceRadar.FlowAttribution.Correlation` joins that bounded current state
  to independently ingested NetFlow/IPFIX rows in
  `platform.ocsf_network_activity` and stamps the matching OCSF row in place as
  `event_type = "attributed_flow"` with process context.
- `flow-collector` remains the raw NetFlow/sFlow ingestion source. Production
  attribution does not publish or consume per-host slices and does not use a
  `flow.attributed.*` JetStream subject.

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
- Local process-attribution observations are persisted as bounded current
  state in `platform.flow_process_attribution_current`. Matching existing
  OCSF Network Activity rows are updated in place, setting the `event_type`
  field to `"attributed_flow"` and adding the attribution context.

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
  OCSF Network Activity rows stamped as `attributed_flow` (PID / process /
  cmdline alongside the classic NetFlow fields).
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
- **COORDINATES WITH** `flow-attribution` — the focused current-path
  acceptance contract is defined by `harden-flow-attribution-pipeline` rather
  than a second delta in this older sidecar proposal.

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
- Modified: `elixir/serviceradar_core/lib/serviceradar/flow_attribution/` —
  current-state persistence and protocol-aware CNPG correlation.
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

- **Phase 1 — OS fingerprinting only (shipped 2026-05-27, then
  license-clean amended).** `rust/netprobe/` skeleton with static musl
  build targets wired into MODULE.bazel plus libpcap-enabled
  dynamic Linux agent packaging *as a stopgap*; sidecar runtime in
  `go/pkg/agent/sidecar/`; IPC v1 protobuf carrying only
  `ApplyConfig` / `Ping` / `FingerprintEvents`; `VisibilityProfile`
  Ash resource with `fingerprint` toggles wired; compiler integration;
  discovery ingestion of fingerprint events; OCSF
  `os.passive_fingerprint` + `metadata.passive_fingerprint` storage;
  minimal Visibility Profile list+edit UI; agent advertises
  `host-network-visibility = enabled` for fingerprint and
  `unavailable` for other surfaces. **Closes Forgejo #3423.**
- **Phase 2 — DPI dissectors (shipped 2026-05-27).** Adds dissectors
  (HTTP/1, HTTP/2, TLS-SNI, DNS, SSH, FTP, QUIC, MQTT, BitTorrent),
  `DpiEvent` stream, device `metadata.dpi` map, DPI UI panel. The
  libpcap-userspace capture path that backs Phase 1 and Phase 2 is
  understood to be a stopgap. **No performance backstops are landed
  on the libpcap path**; that work would be deleted by Phase 3
  anyway. Customers concerned about Phase 2 CPU cost wait for the
  Phase 3 eBPF cutover.
- **Phase 3 — Replace libpcap with kernel-side eBPF (the strategic
  pivot).** This phase rewrites the continuous capture path from
  libpcap-userspace to a kernel-eBPF golden path that matches
  Datadog NPM / Cilium / current-generation Cisco Secure Workload
  architecture. Phase 3 simultaneously ships:
  - **TC ingress + egress eBPF programs** on each allowlisted
    interface with a kernel `flow_table` map; classified flows
    short-circuit in-kernel and never enter userspace.
  - **AF_XDP ring** for delivering the first 8–32 packets of each
    new flow to userspace where the L7 dissectors classify them.
    After classification the result is written back to the
    flow_table and subsequent packets bypass userspace.
  - **SYN-time fingerprinting kprobe** on `tcp_rcv_state_process`
    that emits exactly one p0f-signature event per new TCP connection.
    The in-tree p0f matcher / OS-match ensemble runs once per
    connection; no more userspace work in steady state.
  - **Socket lifecycle kprobes** on `tcp_connect`,
    `inet_csk_accept`, `tcp_close`, `udp_sendmsg`, `udp_recvmsg`
    populating `flow_to_pid` and `process_info` BPF maps. This is
    the original Phase 3 attribution work; it now lives on the
    same eBPF surface as the capture path.
  - **Deletion of the libpcap continuous capture worker** in
    `rust/netprobe/src/capture.rs`. After Phase 3 cutover that
    file is a thin AF_XDP consumer; the `pcap` Cargo dependency
    moves behind a `remote-capture` feature flag used only by
    Phase 5. deb/rpm `Depends` on libpcap drops to `Recommends`.
  - `FlowAttributionEvent` + `ProcessSnapshot` IPC streams
    activated. Local-process map and Process Listeners tab render
    in the UI.
  - **Hard kernel floor: 5.8.** Hosts below the floor advertise
    `host-network-visibility = unavailable` cleanly. There is no
    `degraded` half-state.
- **Phase 4 — NetFlow to application attribution.** Agent-up local
  observation persistence, protocol-aware core-side CNPG correlation,
  `attributed_flow` stamping, and the Attributed Flows view. The retired demo
  host-slice canary is not re-enabled.
- **Phase 5 — Remote pcapng capture sessions.** `CaptureSessions`
  IPC RPC, agent-side session bridge over the existing mTLS control
  stream, `core-elx` session lifecycle + audit, `srctl capture` CLI
  helper, "Start Remote Capture" action on Device / Agent Detail.
  **libpcap returns here, scoped to one operator-initiated session
  at a time behind the `remote-capture` Cargo feature.** The
  continuous code path is unaffected.
- **Phase 6 — Polish and hardening.** Capture interface allowlist
  UI, privacy opt-in toggle polish, runbook expansion, Cisco Secure
  Workload labelling cookbook, Grafana dashboard for eBPF map
  occupancy / sampling budget / flow_table hit ratio.

Phase 1 has shipped. Phase 2 dissectors have shipped. Phase 3 is the
next active phase and the single most important phase for fleet-wide
deployment viability — its work is what unlocks the customer use case
at acceptable CPU cost. No interim libpcap-path optimisation is
planned; the Phase 3 eBPF cutover is the only customer-perf
deliverable in flight.

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
