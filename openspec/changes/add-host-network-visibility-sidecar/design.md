## Context

This proposal supersedes the earlier `add-passive-device-fingerprinting`
proposal after operator review identified three adjacent gaps that share
the same underlying capability surface:

1. Passive OS / device fingerprinting (Forgejo
   [#3423](https://forgejo/issues/3423)).
2. NetFlow-to-application attribution: today the existing
   `flow-collector` ingests sFlow / NetFlow from switches but cannot
   bind a record to a process on the host it traversed, blocking
   workflows such as Cisco Secure Workload labelling / ACL design.
3. Wireshark-style on-site protocol classification: network engineers
   repeatedly tap interfaces on customer sites to classify unknown
   protocols because no continuous, control-plane-visible DPI signal
   exists.

ServiceRadar already has the supporting machinery:

- `serviceradar-agent` (`go/cmd/agent/`, `go/pkg/agent/`) runs on the
  host and **already holds `CAP_NET_RAW`** for ICMP / MTR-style raw
  sockets (`build/packaging/agent/systemd/serviceradar-agent.service`
  lines 18–19, `helm/serviceradar/templates/agent.yaml:95`,
  `helm/serviceradar/values.yaml:725` which explicitly comments that
  the cap is "for ICMP/MTR-style sockets, not BPF loading"). We do
  **not** need to add `CAP_NET_RAW` — but we do need to add `CAP_BPF`
  and `CAP_PERFMON` for eBPF.
- A Bazel + `rules_rust` workspace at `MODULE.bazel` (`rules_rust`
  0.65.0, Rust 1.93) with crate-universe extension `rust_crates`.
- Several production Rust sidecars (`trapd`, `flow-collector`,
  `bmp-collector`, `otel`, `rdp-adapter`) — none of which are currently
  supervised by another ServiceRadar process.
- The `flow-collector` Rust crate at `rust/flow-collector/` with
  established NATS JetStream publishing and per-listener metrics.
- A profile-driven Elixir compiler pipeline
  (`elixir/serviceradar_core/lib/serviceradar/agent_config/compilers/`)
  that resolves SRQL `target_query` against inventory and ships the
  per-device output inside `AgentConfigResponse`.
- An Ash `Device` resource with OCSF `os`, `hw_info`, and `metadata`
  maps already used for enrichment.

Reference implementations surveyed:

- [`huginn-net`](https://crates.io/crates/huginn-net) — maintained
  Rust crate covering p0f-style TCP, HTTP signature, and TLS-JA4
  analysis.
- [`rustnet`](https://github.com/domcyrus/rustnet) — Rust TUI that
  combines pcap capture, a sizeable dissector set (HTTP/1.x, HTTP/2,
  TLS SNI, DNS, SSH, FTP, QUIC, MQTT, BitTorrent), and eBPF
  process-attribution via `aya`, with Landlock-based sandboxing and a
  privilege-drop sequence on Linux. We will **not** depend on rustnet
  as a crate — it is structured as a TUI binary, not an embeddable
  library — but we will reproduce the same architectural patterns and
  depend on the same underlying crates (`aya`, `etherparse`, `pcap`)
  plus `huginn-net` for fingerprinting.

Constraints:

- No Nmap-style active probing.
- No TLS interception or decryption.
- Must coexist with `add-streamed-agent-config` (chunked config
  delivery), `add-unifi-wifi-discovery-parity` (vendor-DB
  fingerprinting), and the existing `flow-collector`.
- Static musl binary for x86_64 and aarch64 Linux.
- Strong privacy posture: no payloads, no URIs, redacted process
  command lines.
- Multi-tenancy: all events and profiles partition-scoped via the
  agent's mTLS identity.

Stakeholders: platform agent team (Go), Rust services team, web-ng /
Elixir team, network engineers (Cisco Secure Workload labelling use
case), security review (eBPF capability surface).

## Goals / Non-Goals

**Goals**

- One sidecar binary covering passive fingerprinting + DPI + per-process
  flow attribution + NetFlow ↔ application attribution.
- Profile-driven scoping via SRQL `target_query` consistent with
  Sysmon / SNMP profiles.
- Bind locally-observed flows to PID / command line / unit / UID /
  container-id with low overhead via eBPF.
- Annotate external NetFlow records with local process attribution
  whenever a 5-tuple matches an observed local socket.
- Enrich both discovered *and* integration-imported devices with
  fingerprint and DPI evidence.
- Establish a reusable `agent-sidecar-runtime` capability for future
  native co-processes.
- Bazel-first builds. `bazel build //rust/netprobe:netprobe` and
  `bazel build //build/packaging/agent:agent_image_amd64` both produce
  ship-ready artefacts.
- Static musl binaries for x86_64-linux-musl and aarch64-linux-musl.

**Non-Goals**

- Active probing.
- TLS decryption.
- Full PCAP retention (a future on-demand export feature is reserved in
  the IPC schema but not implemented in this change).
- HTTP URI or DNS query name capture (privacy-by-default).
- Replacing SNMP / sysmon / mapper / flow-collector signal sources.
- Cross-tenant signal sharing.
- macOS / Windows eBPF support — those platforms get the agent without
  netprobe.

## Decisions

### D1. Binary layout: single `serviceradar-netprobe` sidecar

- **Decision.** Implement as a single Rust binary at `rust/netprobe/`
  named `serviceradar-netprobe`. Subcommands are not required;
  capabilities are controlled by config (`fingerprint`, `dpi`,
  `flow_attribution`, `process_snapshot` toggles in the per-device
  binding).
- **Alternatives.** (a) Three separate sidecars — rejected: triples
  the capability bundle, IPC surface, supervision cost, and operator
  cognitive load. (b) One sidecar with subcommands — equivalent in
  practice; rejected to keep the supervisor model simple.
- **Rationale.** Operator UX, OS capability surface, and supervision
  cost all benefit from one process. Future expansion (Wireshark-like
  export) becomes another toggle, not another binary.

### D2. Cherry-pick from rustnet rather than depend on it

- **Decision.** Treat `rustnet` as a reference implementation. Depend
  directly on the upstream crates rustnet itself uses — `huginn-net`,
  `aya` (with `aya-ebpf` and `aya-log`), `etherparse`, `pktparse-rs`,
  `pcap` — plus our own glue. Re-implement only the patterns we need
  (process map, dissector pipeline assembly, capability sequencing,
  Landlock sandboxing if/when we want it), not the TUI layer.
- **Alternatives.** (a) Fork rustnet, strip the TUI — rejected: we
  would inherit a fork-maintenance burden, a TUI we never use, MIT
  attribution obligations across un-stripped paths, and a build profile
  oriented around a single-user interactive binary. (b) Add rustnet as
  a Cargo dependency — rejected because rustnet is not published as a
  library; its public modules are not stable API.
- **Rationale.** Cleaner ownership boundary, smaller binary, no fork
  drift, license obligations only where we directly import upstream
  crates.

### D3. Sidecar lifecycle: agent-supervised, UDS IPC

- **Decision.** A new `go/pkg/agent/sidecar/` package implements a
  generic sidecar manager (the basis of the `agent-sidecar-runtime`
  capability). For `netprobe` it:
  - resolves the binary path (default
    `/usr/local/lib/serviceradar/bin/serviceradar-netprobe`,
    overridable);
  - creates a per-sidecar socket dir
    (`/run/serviceradar/netprobe/`) at mode `0700`;
  - spawns the child with
    `--socket=/run/serviceradar/netprobe/ipc.sock --config=<json>`;
  - opens a UDS connection for control RPCs and four server-streamed
    event channels (fingerprint, DPI, flow attribution, process
    snapshot);
  - runs a 5-second health probe; three consecutive failures or
    unexpected exit trigger graceful kill (SIGTERM → 5s grace →
    SIGKILL) + restart under exponential back-off capped at 60s;
  - circuit-breaks after five restarts/min;
  - surfaces sidecar state in the agent's `StatusResponse`.
- **Alternatives.** (a) systemd-managed sidecar — rejected, no
  systemd in OCI deployments; (b) stdio framing — rejected, want a
  long-lived bidirectional control channel with proper framing and
  multiple streams.
- **Rationale.** Pattern matches Datadog system-probe; UDS works
  identically across deb/rpm/OCI; multiple streams over one socket
  keep the supervisor model trivial.

### D4. Packet acquisition: pcap inside the sidecar, not the agent

- **Decision.** `netprobe` opens libpcap directly via the `pcap` crate
  on the operator-allowlisted interfaces. The Go agent does not touch
  raw packets.
- **Alternatives.** (a) Agent does pcap and forwards packets over UDS
  — rejected: doubles bytes-per-packet across IPC, requires the agent
  to handle bursty back-pressure, and offers no security benefit
  (agent already holds `CAP_NET_RAW`). (b) eBPF XDP — out of scope for
  v1; the libpcap path matches huginn-net's intended integration and
  is portable.
- **Rationale.** Simpler control flow, no IPC packet duplication. The
  agent's existing `CAP_NET_RAW` is for ICMP/MTR scanners and is
  unrelated to BPF.

### D5. eBPF programs and capability requirements

- **Decision.** `netprobe` loads eBPF programs via `aya`:
  - `kprobe/tcp_connect`, `kretprobe/inet_csk_accept`,
    `kprobe/tcp_close` for TCP socket lifecycle.
  - `tracepoint/syscalls/sys_enter_sendto` +
    `sys_enter_recvfrom` (or `kprobe/udp_sendmsg` + `udp_recvmsg`)
    for UDP.
  - `tracepoint/sock/inet_sock_set_state` as a generic backfill.
  - For QUIC, lifecycle is inferred from the underlying UDP flows
    combined with DPI (rather than a dedicated QUIC kprobe).
  - All maps are pinned under `/sys/fs/bpf/serviceradar/netprobe/`
    with `0700` perms so a sidecar restart can reattach to existing
    programs without losing in-flight state.
- The binary acquires `CAP_BPF` and `CAP_PERFMON` (Linux ≥ 5.8) at
  start, loads programs, opens pcap handles, then drops to a non-root
  UID. On kernels older than 5.8 the binary refuses to start eBPF
  features and degrades to fingerprint + DPI without process
  attribution; that degradation is reported in agent capability
  advertisement.
- **Alternatives.** (a) `libbpf-rs` instead of `aya` — equally
  viable; chose `aya` to keep the entire binary pure Rust (no C
  toolchain at build time, simpler musl static link). (b)
  `CAP_SYS_ADMIN` fallback — rejected by policy; modern kernels
  expose the split caps, and `CAP_SYS_ADMIN` is too broad to grant a
  sidecar.
- **Rationale.** `aya` is the pure-Rust eBPF path used by rustnet
  itself and aligns with our musl-static goal. The capability
  requirements are scoped to the sidecar; the agent never gains
  `CAP_BPF`.

### D6. IPC protocol: framed protobuf, multiple streams

- **Decision.** `proto/agent/netprobe/v1/netprobe.proto` defines:
  - `ApplyConfig(VisibilityAgentConfig)` — capture interfaces,
    per-device bindings, retention.
  - `Ping()/PingAck()` — liveness.
  - `FingerprintEvents(stream FingerprintEvent)` — TCP / TLS / HTTP
    signatures.
  - `DpiEvents(stream DpiEvent)` — per-flow protocol classification.
  - `FlowAttributionEvents(stream FlowAttributionEvent)` — local
    flow with PID, comm, redacted-cmdline, uid, container-id.
  - `ProcessSnapshots(stream ProcessSnapshot)` — periodic listener
    map.
  - `IngestExternalFlows(stream ExternalFlowRecord)` — external
    NetFlow records the agent has forwarded for attribution.
  - Reserved field numbers for a future `PacketExportEvents` stream.
- Wire format: length-prefixed protobuf frames over UDS, 4-byte
  big-endian length prefix, max frame size 4 MiB. No full gRPC
  runtime in the sidecar (keeps the static binary small).
- **Alternatives.** (a) Full gRPC — adds hyper/tonic to a musl-static
  binary unnecessarily. (b) JSON-RPC — debug-friendly but bloats
  high-rate flow events.
- **Rationale.** Reuses our existing protoc/buf tooling and keeps the
  sidecar binary small.

### D7. Unified profile model

- **Decision.** A single `Serviceradar.Inventory.VisibilityProfile`
  Ash resource with these attributes:
  - `name` (string, unique within partition).
  - `description` (string, optional).
  - `enabled` (boolean, default false).
  - `target_query` (SRQL, defaults to `in:devices` when blank).
  - `priority` (integer, higher evaluates first).
  - `fingerprint` (map: `tcp`, `tls`, `http` booleans).
  - `dpi` (map: `enabled` boolean + `protocols` list with allowlist
    of supported dissectors).
  - `flow_attribution` (map: `tcp`, `udp`, `quic` booleans).
  - `process_snapshot_interval_s` (integer, 0 = disabled).
  - `sample_interval_ms` (integer, 0 = no per-pair rate limit).
  - `retention_days` (integer, default 30).
  - partition (`partition_id`).
  - standard temporal fields, policies via `Ash.Policy.Authorizer`.
- Per-device bindings are compiled by a single
  `Serviceradar.AgentConfig.Compilers.VisibilityCompiler` using
  `SrqlTargetResolver.resolve_for_device/2`.
- **Alternatives.** (a) Three separate profile resources —
  `FingerprintProfile`, `DpiProfile`, `FlowAttributionProfile`.
  Rejected: triples the operator UX surface, requires operators to
  coordinate three SRQL scopes for the same device, and the
  capabilities co-vary in practice.
- **Rationale.** One profile per scope matches how operators think
  about visibility, mirrors the sysmon pattern, and keeps the
  compiler emitting one binding per device.

### D8. Storage: extend OCSF maps; new attributed_flow event type

- **Decision.** No new top-level tables. Extend existing maps:
  - `device.os.passive_fingerprint` — `{family, version, confidence,
    source: "huginn-net", observed_at}`.
  - `device.metadata.passive_fingerprint` — protocol-specific
    signature payloads keyed by `tcp`, `tls`, `http`, each with
    `observed_at`.
  - `device.metadata.dpi` — per-protocol counters and
    last-observation timestamps (no payloads).
  - `device.metadata.local_processes` — periodic snapshot of
    listening sockets and their owning processes; bounded
    cardinality with LRU eviction.
- Attributed flow records ride the **existing** flow pipeline. We
  add a new `attributed_flow` event type emitted on
  `flow.attributed.<partition>` (or whatever the existing
  flow-collector subject convention is — to be confirmed during
  implementation review of `flow-collector`'s spec).
- **Alternatives.** (a) New `process_attribution` table — rejected as
  premature; the existing flow pipeline already gives us time-series
  + retention.
- **Rationale.** Keeps the schema impact minimal and lets the existing
  enrichment matcher and flow UI consume new signals without new
  storage.

### D9. Imported-device coverage via existing IP-alias resolution

- **Decision.** When `netprobe` reports any event referencing an IP
  not local to the host (e.g. a fingerprint of a remote endpoint
  observed on a captured interface), the agent looks up the canonical
  device via `device-identity-reconciliation`'s `IP Alias Resolution`
  and emits a `DiscoverySourcePassiveNetprobe` ingestion record. For
  events referencing the host's own IPs (e.g. process attribution),
  the agent annotates the agent's host device record directly.
- **Alternatives.** (a) Sidecar-maintained IP→device map — rejected;
  duplicates reconciliation pipeline work.
- **Rationale.** Reuses the proven multi-source convergence path for
  Armis / NetBox / UniFi imported devices.

### D10. Bazel: musl triples, eBPF object build, packaging

- **Decision.**
  - `MODULE.bazel`: extend
    `rust.toolchain(extra_target_triples=[…])` with
    `x86_64-unknown-linux-musl` and `aarch64-unknown-linux-musl`.
  - `.cargo/config.toml`: musl linker entries
    (`x86_64-linux-musl-gcc`, `aarch64-linux-musl-gcc`).
  - `rust/netprobe/BUILD.bazel`: a `rust_binary` plus a
    `cargo_build_script` that invokes `bpf-linker` / `aya-build` to
    compile the eBPF programs into the binary as embedded objects
    (no separate eBPF artefact to ship).
  - `Cargo.toml` workspace: add `"rust/netprobe"` to `members`.
  - `build/packaging/agent/BUILD.bazel`,
    `build/packaging/packages.bzl`, `docker/images/BUILD.bazel`: add
    `//rust/netprobe:netprobe` to the agent payload at
    `/usr/local/lib/serviceradar/bin/serviceradar-netprobe`.
  - deb/rpm postinst:
    `setcap cap_bpf,cap_perfmon,cap_net_raw+ep /usr/local/lib/serviceradar/bin/serviceradar-netprobe`.
  - Helm agent template: add `BPF` and `PERFMON` to
    `securityContext.capabilities.add` for the agent pod (NET_RAW
    already present).
- **Alternatives.** (a) Build eBPF objects out-of-tree and ship them
  as separate files — rejected, complicates packaging and signing.
- **Rationale.** Single-artefact distribution, capability surface
  scoped to the sidecar.

### D11. Privacy redaction at the IPC boundary

- **Decision.** The sidecar applies redaction before any event
  crosses the IPC boundary, not at the agent:
  - No packet payloads ever cross IPC.
  - No HTTP URIs / request bodies / response bodies — only
    `Server`, `User-Agent`, `Accept-Language` headers used by the
    signature engine.
  - DNS captured as 5-tuple + record-type + RCODE only; query names
    are dropped by default and opt-in via profile.
  - Command line strings are truncated to the binary path + a hash
    of the remaining arguments (`/usr/sbin/nginx <args-hash>`);
    opt-in full capture per profile.
  - Process environment variables are never captured.
- **Alternatives.** (a) Send raw and redact agent-side — rejected;
  raw data would briefly live in the agent's address space.
- **Rationale.** Privacy-by-default. The sidecar holds the most
  sensitive data and is the right enforcement boundary.

### D12. Capture-interface allowlist with deny-by-default

- **Decision.** `VisibilityAgentConfig.capture_interfaces` is an
  explicit list. The sidecar refuses `any`, refuses wildcards, and
  refuses any interface not in the list. New interfaces require
  explicit operator opt-in via the agent settings UI.
- **Rationale.** Avoids surprise capture on management or storage
  interfaces, especially on hosts running multiple VLANs / network
  namespaces.

### D13a. Remote pcapng capture: end-to-end transport

- **Decision.** Reuse ServiceRadar's existing trust chain end-to-end.
  Agents do not talk to `core-elx` directly; the agent side terminates
  at `agent-gateway` over mTLS gRPC, and `core-elx` ↔ `agent-gateway`
  uses ERTS RPC (Erlang distribution). The user side terminates at
  `web-ng`, which dispatches to `core-elx` over ERTS RPC. The flow:
  - `srctl capture` authenticates against `web-ng` using the CLI
    device-auth path defined by `add-cli-device-auth`. `web-ng` is
    the user-facing termination point; agents have no role in this
    auth.
  - `web-ng` dispatches the request to `core-elx` over ERTS RPC.
  - `core-elx` validates RBAC (`agent_capture:remote` on the target
    agent's partition), creates a `RemotePacketCaptureSession` Ash
    record (status `requested`, requesting user, agent id, BPF
    filter, snaplen, duration, byte cap), and emits an audit event.
  - `core-elx` invokes the agent-gateway command bus over ERTS RPC.
  - `agent-gateway` forwards `StartRemoteCaptureSession` to the
    target agent over the existing mTLS control stream (per
    `agent-connectivity`'s `Command bus for on-demand actions`).
  - The agent calls a new
    `CaptureSessions(StartRemoteCapture) returns (stream PcapngBlock)`
    RPC on `netprobe` over the existing UDS.
  - pcapng blocks flow back upstream in reverse: `netprobe` → agent
    (UDS) → `agent-gateway` (gRPC server-streaming over the existing
    mTLS HTTP/2 connection) → `core-elx` (ERTS RPC) → `web-ng`
    (HTTPS stream) → `srctl`.
- **Alternatives.** (a) Direct client → agent gRPC tunnel via the
  gateway, with `core-elx` only handling the handshake. Rejected:
  loses inline RBAC enforcement, complicates session termination,
  and breaks audit guarantees if the gateway is bypassed at any
  point. (b) `web-ng` dispatches *directly* to `agent-gateway`,
  skipping `core-elx` entirely on the assumption that the broker is
  pure transport. Tracked as open question 11; would only be viable
  if `core-elx`-side session bookkeeping moves elsewhere. (c) Old-
  style `rpcapd` listening port on the agent. Rejected: requires a
  new firewall hole and a new transport, which the agent's edge-
  network deployment explicitly avoids.
- **Rationale.** Reuses every existing trust boundary in
  ServiceRadar's edge story (CLI device auth at `web-ng`, ERTS RPC
  between Erlang nodes, mTLS gRPC from `agent-gateway` to the
  agent). No new attack surface; same observability and
  forwarder-rate-limiting we already operate.

### D13b. Capture session lifecycle and bounds

- **Decision.** A `RemotePacketCaptureSession` carries:
  - `session_id` (ULID).
  - `agent_id`, `target_interfaces` (must be a subset of the agent's
    `visibility_config.capture_interfaces` — the existing
    allowlist).
  - `bpf_filter` (string; libpcap-compatible).
  - `snaplen` (default 96, max 65535).
  - `duration_s` (default 60, max 600 in Phase 5; revisit later).
  - `byte_cap` (default 50 MiB, max 1 GiB).
  - `requested_by_user_id`, `requested_at`.
  - `state`: `requested → authorised → active → completed | aborted | timed_out | denied`.
  - `bytes_streamed`, `last_block_at`.
- Hard caps enforced at three layers:
  - `core-elx` rejects requests exceeding partition-level caps
    (configurable per tenant, defaults match the per-session
    defaults above).
  - The agent independently enforces the same caps; agent caps are
    floor-bound (agent can be more restrictive, never more
    permissive).
  - `netprobe` is the final enforcer: when `duration_s` elapses or
    `byte_cap` is reached, the sidecar closes the pcap handle and
    emits a terminal `PcapngBlock` with `final = true`.
- Concurrent-session cap per agent: 1 in Phase 5 (single active
  capture per agent at any time). Multi-session support is deferred
  to a later change.
- **Alternatives.** (a) Unbounded sessions with operator-driven
  termination only. Rejected: operators forget; idle sessions are
  the #1 cause of `rpcapd` runaway disk use.
- **Rationale.** Time- and byte-bounded sessions, enforced at three
  independent layers, are the minimum for safely exposing packet
  capture on a tenant's hosts.

### D13c. pcapng wire format and IPC stream

- **Decision.** `netprobe` emits raw pcapng over the IPC stream:
  Section Header Block, Interface Description Block(s), and Enhanced
  Packet Blocks per RFC draft `pcapng`. No re-encoding at any hop.
  The first block in any stream MUST be the SHB; the IDB(s) follow
  immediately. Each subsequent frame on the IPC stream is one
  pcapng block, length-prefixed by the existing IPC framing
  (4-byte big-endian, max 4 MiB).
- The agent and gateway forward bytes unchanged. `core-elx` does
  not parse pcapng — it only counts bytes for the session record
  and authorises the stream.
- `srctl capture` writes pcapng to stdout without re-encoding.
- **Alternatives.** (a) Custom framing with per-packet metadata
  envelope. Rejected: requires a custom decoder at the client edge
  and breaks the "pipe into wireshark -k -i -" UX.
- **Rationale.** Wireshark, tshark, and every other pcapng-aware
  tool consume the stream directly. Zero re-encoding latency.

### D13d. `srctl` CLI: rename the Go binary + port device-code auth

- **Decision.** The existing Go CLI at `go/cmd/cli/` (currently
  installed as `serviceradar-cli` and used for `enroll`, `user
  create`, …) is renamed to `srctl` as part of this proposal. The
  binary becomes ServiceRadar's ops/runtime CLI; the existing
  `@carverauto/serviceradar-cli` npm binary remains in place but
  stays scoped to dashboard SDK authoring. Specifically:
  - Rename: the Bazel target and packaging output produce
    `srctl` as the primary binary. A `serviceradar-cli` symlink
    pointing at `srctl` is shipped for one release cycle so
    existing scripts and docs (`serviceradar-cli enroll`, …)
    keep working; the symlink is deprecated and slated for
    removal in a subsequent release.
  - Device-code auth client: port the RFC 8628 client logic from
    the JS CLI into `srctl`, hitting the same
    `add-cli-device-auth` server endpoints. The Go binary stores
    the issued Guardian JWT in the OS-appropriate user
    credentials directory (`$XDG_CONFIG_HOME/serviceradar/` on
    Linux, `~/Library/Application Support/serviceradar/` on
    macOS, `%APPDATA%\serviceradar\` on Windows) with `0600`
    perms on the credentials file.
  - `srctl auth login` / `auth status` / `auth logout`
    subcommands mirror the JS CLI's surface so engineer
    documentation reads the same regardless of which CLI is in
    play.
  - New `srctl capture` subcommand takes `--agent`,
    `--interface`, `--filter`, `--duration`, `--snaplen`,
    `--byte-cap`. Auth comes from the cached device-code token
    (no new auth flags). Session metadata prints to stderr
    (session id, expected termination time, audit-record URL);
    pcapng streams to stdout for piping into `wireshark -k -i -`
    or `tshark -i -`. Exits 0 on graceful session completion,
    distinct non-zero codes for auth failure, RBAC denial, BPF
    parse failure, agent unreachable, or upstream cancellation.
- **Alternatives.** (a) Use the JS CLI for capture instead. Rejected
  per the explicit user direction during proposal review: the JS
  CLI's stated purpose is dashboard SDK authoring; Node's binary
  stdout has subtle encoding edge cases that risk corrupting
  pcapng on a `tshark -r -` pipe; Go produces a single-binary
  workstation install with no runtime dependency. (b) Brand-new CLI
  written from scratch. Rejected: existing Go CLI already has
  account-lifecycle subcommands that fit alongside `capture`. (c)
  Browser-based capture launcher only. Rejected: engineers want
  the Wireshark / tshark UX they already use daily.
- **Rationale.** Two CLIs, clearly differentiated by purpose: JS for
  dashboard SDK authoring, `srctl` for ops/runtime/agent
  operations. The rename + device-code port is the right moment to
  draw that line.

### D13e. RBAC, audit, and tenancy

- **Decision.** A new RBAC permission `agent_capture:remote` is
  added to `Serviceradar.Identity.RBAC.Catalog`. By default no
  role holds it; tenant admins assign it explicitly. A separate
  `agent_capture:audit_view` permission gates viewing of historic
  capture sessions and their byte counts.
- Every transition of `RemotePacketCaptureSession.state` emits a
  durable audit record (request, authorise, start, terminate cause,
  byte total) reusing the existing audit log capability.
- Sessions are partition-scoped: a user with the permission in
  tenant A cannot start a capture on tenant B's agent even if the
  agents share a gateway.
- **Alternatives.** None considered — RBAC + audit are mandatory
  for any packet capture surface.
- **Rationale.** Security review will gate this feature on the
  audit trail being complete and the permission being
  separately-grantable.

### D13. NetFlow ↔ application attribution data flow

- **Decision.** `flow-collector` publishes a *per-host slice* of
  ingested NetFlow records on a new subject
  (`flow.host-slice.<agent-id>` or equivalent) for every agent that
  has advertised the `host-network-visibility` capability. The agent
  subscribes to its own slice, forwards the records to `netprobe`
  via `IngestExternalFlows`, and republishes the annotated stream as
  `attributed_flow` records on the existing flow pipeline.
- For agents not running `netprobe`, `flow-collector` simply does not
  publish a per-host slice for that agent; the existing flow pipeline
  is unchanged.
- **Alternatives.** (a) Forward *all* NetFlow to *every* agent —
  rejected, scales poorly. (b) Let `netprobe` itself ingest NetFlow
  directly from switches — rejected, that duplicates `flow-collector`
  and pulls UDP-listener concerns into the sidecar.
- **Rationale.** Per-host slicing keeps the data scope tight, leans
  on `flow-collector` for ingestion correctness, and keeps `netprobe`
  focused on host-level observation.

## Risks / Trade-offs

| Risk | Mitigation |
|---|---|
| eBPF program compatibility across kernels. | Target a minimum kernel of 5.8; degrade gracefully (DPI + fingerprint without process attribution) on older kernels; surface kernel version + program-load failures in agent status. |
| `huginn-net` upstream regression. | Pin to a known release in `Cargo.toml`; renovate-bot updates gated by agent E2E. |
| `aya` upstream churn (still pre-1.0). | Pin to a tested release and budget for periodic version bumps; document this in the runbook. |
| Sidecar crash storms (e.g. malformed packet bug). | Exponential restart back-off, circuit-breaker, surface as agent health warning. |
| Static musl build pulls in conflicting C-deps. | Validated in Phase 1 by `bazel build --platforms=...linux-musl`; fall back to glibc-static-stdlib with documented portability constraints if blocked. |
| Process-attribution cardinality explosion on busy hosts. | Bounded LRU eviction, per-(pid, 5-tuple) deduplication window, sample-interval rate limit per profile, drop counters surfaced as metrics. |
| Privacy: cmdline / DNS leakage. | Default redaction at the sidecar boundary; opt-in via profile flag; clear runbook. |
| Capability creep on the agent process. | All eBPF and pcap capabilities scoped to the sidecar binary via file capabilities or per-process `securityContext`. |
| Overlap with `add-unifi-wifi-discovery-parity` enrichment rules. | Both feed the existing rule matcher; precedence handled by `Classification Provenance`. |
| Operator confusion between per-device fingerprint signals (remote endpoints observed on wire) and host attribution (local processes on agent host). | UI distinguishes "Network Visibility" (about the device being viewed) from "Process Listeners" (about the agent host) on Device Detail. |
| Multi-tenant leakage. | Profiles are partition-scoped Ash resources; events carry `partition_id` from agent mTLS identity; flow-collector per-host slicing is partition-bounded. |
| Remote-capture sessions expose full packet payloads (in contrast to the redaction posture for passive observation). | New `agent_capture:remote` RBAC permission off by default; per-session time + byte caps enforced at three layers; every state transition audit-logged; partition-scoped; tenant-configurable cap ceilings; concurrent-session cap of 1 per agent in Phase 5. |
| Long-lived remote capture sessions exhaust agent or gateway egress bandwidth. | Per-session byte cap (default 50 MiB, max 1 GiB); duration cap (default 60 s, max 600 s in Phase 5); per-agent concurrent-session cap of 1; gateway-side rate limit consistent with existing command-bus quotas; agent surfaces an "active capture session" indicator so operators can see noise sources at a glance. |
| Engineer's `srctl capture` process dies mid-stream and leaves a dangling session. | `core-elx` detects the streaming endpoint close, sends a `StopRemoteCapture` to the agent over the command bus, and the agent forwards a `cancel` to `netprobe`. Sessions also self-terminate on duration/byte cap regardless of client liveness. |

## Migration Plan

The change is additive: no migrations required for existing devices, no
behavioural change until an operator creates an enabled
`VisibilityProfile`. The earlier `add-passive-device-fingerprinting`
proposal directory is removed in the same commit set as this proposal
(this change supersedes it; no released artefacts depend on its scope).

Phased rollout (Phase 1 is the minimum-viable shipping increment and
the only phase scoped for the *first* release of this work):

1. **Phase 1 — OS fingerprinting only.** `rust/netprobe/` skeleton +
   `huginn-net` integration; static musl builds + agent packaging;
   sidecar runtime (`go/pkg/agent/sidecar/`); IPC v1 protobuf with
   only `ApplyConfig` / `Ping` / `FingerprintEvents` (other event
   channels reserved for future variants but not implemented);
   `VisibilityProfile` Ash resource with only `fingerprint` toggles
   wired; compiler + discovery ingestion + OCSF storage; minimal
   profile management UI (fingerprint section only); agent
   advertises `host-network-visibility = enabled` for fingerprint,
   `unavailable` for every other surface. **Closes Forgejo #3423.**
2. **Phase 2 — DPI.** Add dissectors (HTTP/1, HTTP/2 cleartext,
   TLS-SNI, DNS, SSH, FTP, QUIC, MQTT, BitTorrent), `DpiEvent`
   stream, `metadata.dpi` storage, DPI UI panel and per-protocol
   profile toggles.
3. **Phase 3 — eBPF flow attribution + process snapshot.** Load
   eBPF programs (kernel ≥ 5.8); emit `FlowAttributionEvent` +
   `ProcessSnapshot`; persist `metadata.local_processes`; UI
   Process Listeners tab; degraded-mode advertising for older
   kernels.
4. **Phase 4 — NetFlow ↔ application attribution.**
   `flow-collector` per-host slice publish; agent forwarding into
   `netprobe`; `attributed_flow` republish; Attributed Flows view.
5. **Phase 5 — Remote pcapng capture sessions.** `CaptureSessions`
   IPC RPC and agent-side bridge (per D13a–D13e); `core-elx`
   session lifecycle + audit + RBAC; `srctl capture` CLI helper;
   "Start Remote Capture" action on Device / Agent Detail with
   session-state display.
6. **Phase 6 — Polish and hardening.** Capture-interface allowlist
   editor; privacy opt-in toggles; runbook; Cisco Secure Workload
   labelling cookbook; Grafana dashboard.

Phases 2–5 have no required ordering between them; teams can pick
based on operator demand. Phase 1 must land first because every
later phase depends on its IPC, sidecar, and profile scaffolding.

Rollback per phase:

- **Phase 1.** Disable all `VisibilityProfile` records → compiler
  emits empty per-device map → sidecar drops to idle. Removing the
  sidecar binary from the agent package fully reverts behaviour;
  OCSF map additions are forward-compatible keys with no destructive
  cleanup.
- **Phases 2–4.** Per-capability toggles on `VisibilityProfile`
  let operators disable individual surfaces without taking the
  whole feature down.
- **Phase 5.** Revoke `agent_capture:remote` from every role to
  hard-disable remote capture without affecting passive surfaces;
  alternatively, set partition-level concurrent-session cap to 0.

## Open Questions

1. **`aya` vs `libbpf-rs` final pick.** Both are mature. Recommend
   `aya` for pure-Rust simplicity (no C toolchain at build time;
   easier musl static link) but confirm during Phase 4 spike.
2. **eBPF program signing / verification.** Do we want to ship signed
   eBPF programs and verify at load time? Default: no, the binary
   itself is signed by the agent release pipeline; revisit if a
   regulated customer requires it.
3. **Container-id resolution.** Mapping a PID to a container-id
   requires walking `/proc/<pid>/cgroup` and matching against
   `containerd` / `cri-o` / `docker` socket-known identifiers. For
   v1: resolve when the cgroup path matches a containerd or docker
   regex; report `unknown` otherwise. Confirm.
4. **Profile granularity vs sidecar load.** Should `flow_attribution`
   be a global enable (per agent) rather than per-device? eBPF
   programs attach globally and only the post-filter respects per-
   device scope. For v1 keep the per-device knob in the profile but
   note that turning it on for *any* device incurs the global eBPF
   load cost.
5. **NetFlow slice subject naming.** Today's `flow-collector` subjects
   were not enumerated during proposal authoring. Confirm the exact
   subject scheme during implementation review of the `flow-collector`
   spec.
6. **macOS / Windows agent.** Initial scope ships netprobe only on
   Linux. Non-Linux agents advertise `host-network-visibility` as
   unavailable. Confirm acceptable.
7. **Long-term packet export (Wireshark `extcap` integration).**
   `srctl capture` pipes pcapng to stdout in Phase 5, which already
   works with `wireshark -k -i -`. A native Wireshark `extcap`
   plugin so engineers can pick a ServiceRadar agent from the
   Wireshark capture-source picker is a follow-up.
8. **Tenant cap ceilings.** What are the right default tenant-level
   maxima for `duration_s`, `byte_cap`, and concurrent sessions?
   Phase 5 defaults (60 s / 50 MiB / 1) are intentionally
   conservative. Confirm with security review before raising.
9. **Capture data staging.** Should `core-elx` *optionally* stage
   completed captures into object storage for asynchronous
   retrieval (`srctl capture history`)? Defaults: no staging,
   captures flow through `core-elx` only as live bytes. Revisit
   when operators ask.
10. **Audit detail level.** Do we record the BPF filter verbatim in
    the audit log, or hash + summarise? Verbatim is operator-
    friendly but a BPF filter can encode IP allowlists. Lean
    verbatim with a redaction hook; confirm with security review.
11. **Skipping `core-elx` on the user-facing leg.** ServiceRadar
    has a precedent for `web-ng` dispatching straight to
    `agent-gateway` when a request does not need core-side
    processing. Remote capture *does* need core-side processing
    (RBAC, audit, session record, tenant cap enforcement), so this
    proposal puts `core-elx` in the path. Revisit if a future
    iteration moves session bookkeeping into `web-ng` or
    `agent-gateway` directly.
