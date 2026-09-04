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

- The original Phase 1 plan considered `huginn-net` for p0f-style TCP,
  HTTP signature, and TLS-JA4 analysis. D14 supersedes that dependency
  with ServiceRadar-owned p0f / JA4-base / HASSH code.
- [`rustnet`](https://github.com/domcyrus/rustnet) — Rust TUI that
  combines pcap capture, a sizeable dissector set (HTTP/1.x, HTTP/2,
  TLS SNI, DNS, SSH, FTP, QUIC, MQTT, BitTorrent), and eBPF
  process-attribution via `aya`, with Landlock-based sandboxing and a
  privilege-drop sequence on Linux. We will **not** depend on rustnet
  as a crate — it is structured as a TUI binary, not an embeddable
  library — but we will reproduce the same architectural patterns and
  depend on the same underlying crates (`aya`, `etherparse`, `pcap`).
  Fingerprinting is handled by the license-clean stack in D14.

Constraints:

- No Nmap-style active probing.
- No TLS interception or decryption.
- Must coexist with `add-streamed-agent-config` (chunked config
  delivery), `add-unifi-wifi-discovery-parity` (vendor-DB
  fingerprinting), and the existing `flow-collector`.
- Static musl build targets for x86_64 and aarch64 Linux; Phase 1
  shipping artifacts use the libpcap-enabled dynamic Linux build until
  static packet capture support is available.
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
  flow attribution, with core-side NetFlow-to-application correlation.
- Profile-driven scoping via SRQL `target_query` consistent with
  Sysmon / SNMP profiles.
- Bind locally-observed flows to PID / command line / unit / UID /
  container-id with low overhead via eBPF.
- Emit local socket/process observations agent-up so core can correlate them
  with independently ingested NetFlow/IPFIX when the protocol-specific tuple
  and time window match.
- Enrich both discovered *and* integration-imported devices with
  fingerprint and DPI evidence.
- Establish a reusable `agent-sidecar-runtime` capability for future
  native co-processes.
- Bazel-first builds. `bazel build //rust/netprobe:netprobe` and
  `bazel build //build/packaging/agent:agent_image_amd64` both produce
  ship-ready artefacts.
- Static musl binaries remain buildable for x86_64-linux-musl and
  aarch64-linux-musl as portability targets.

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
  directly on the upstream crates rustnet itself uses where they fit:
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

### D4. Packet acquisition: kernel-side eBPF, not libpcap

- **Decision (revised 2026-05-27).** Continuous packet observation
  runs entirely in the kernel via eBPF. The `netprobe` sidecar
  attaches a TC ingress program and a TC egress program to each
  allowlisted interface; the TC programs maintain a kernel BPF
  flow-table map keyed by canonical 5-tuple; packets matching a
  classified flow have their byte/packet counters bumped in-kernel
  and never cross into userspace. The first 8–32 packets of each new
  flow are redirected via an AF_XDP ring to userspace where the L7
  dissector pack classifies them and writes the result back into the
  flow_table map. TCP SYN signatures are emitted by a single
  kprobe on `tcp_rcv_state_process` (or the kernel-version-appropriate
  equivalent), giving us one event per new connection rather than
  per-packet fingerprinting. Socket lifecycle and process attribution
  (Phase 3 plan, expanded here) ride the same eBPF surface via
  kprobes on `tcp_connect` / `inet_csk_accept` / `tcp_close` /
  `udp_sendmsg` / `udp_recvmsg`. **libpcap is removed from the
  continuous capture path entirely**; the `pcap` Cargo dependency is
  retained only behind a `remote-capture` feature flag for the
  Phase 5 operator-initiated pcapng tunnel.
- **History.** Phase 1 / Phase 2 §16 shipped a userspace libpcap
  capture worker as a stopgap. That implementation is replaced by
  the eBPF capture path in Phase 3 (tasks §18.*). The libpcap
  capture worker is deleted from the continuous code base after the
  Phase 3 cutover; the `rust/netprobe/src/capture.rs` file becomes a
  thin AF_XDP consumer.
- **Alternatives.**
  - **Keep libpcap as a fallback** for older kernels — rejected
    2026-05-27 per project direction. Two code paths to maintain
    indefinitely; the libpcap path produces CPU profiles that don't
    meet the fleet-wide deployment use case our customers demand.
    Hosts on kernels < 5.8 advertise `host-network-visibility =
    unavailable` instead of running a degraded path.
  - **XDP instead of TC** — XDP runs earlier in the receive path and
    is lower-overhead, but is ingress-only and requires explicit
    driver support that varies by NIC. TC programs run on both
    ingress and egress, work on any interface (including veth, lo,
    bond, vlan), and provide the symmetric observation we need for
    flow accounting. Choose TC for portability; revisit XDP for
    fast-path NIC offload as a follow-up.
  - **`cilium/ebpf` (Go) instead of `aya` (Rust)** — `aya` keeps the
    sidecar a single static-musl Rust binary; switching to a Go
    eBPF loader would require either a second binary or a Go-Rust
    FFI surface. Stick with `aya`.
- **Rationale.** Matches the architectural baseline of Datadog NPM,
  Cilium/Hubble, and current-generation Cisco Secure Workload. Every
  serious continuous-host-visibility product moved away from
  libpcap-userspace for the same reason: per-packet kernel→user
  transitions are the CPU bottleneck. Eliminates the per-packet
  userspace cost for 80–95% of traffic by keeping classified flows
  in-kernel.

### D4b. Kernel version floor: hard cut at 5.8

- **Decision.** `serviceradar-netprobe` refuses to start its
  continuous capture worker on kernels older than 5.8. The `CAP_BPF`
  / `CAP_PERFMON` split (introduced in 5.8) is required; AF_XDP map
  allocation requires 5.4+; BTF-CO-RE for portable eBPF needs 5.5+.
  Setting the floor at 5.8 lets us require all three without an
  additional matrix of kernel-feature shims.
- **Coverage.** RHEL 9 (5.14), Ubuntu 22.04 LTS (5.15) and 24.04
  (6.8), Amazon Linux 2023 (6.1), SLES 15 SP4+ (5.14) all satisfy.
  RHEL 7 (3.10, EOL'd June 2024), Ubuntu 18.04 (4.15, EOL'd
  June 2023), and vendor kernels < 5.8 do not. Customers on those
  platforms see netprobe advertise `host-network-visibility =
  unavailable` and run without continuous capture.
- **Alternative considered.** Maintain a kernel-version compatibility
  shim allowing some functionality on 5.4+. Rejected — adds two
  permanent code paths and we've already committed to no `degraded`
  half-state per the spec amendment.
- **Rationale.** Matches the practical floor that Datadog's
  system-probe and Cilium both target in production. Older kernels
  are out of upstream distro support anyway.

### D4c. Flow classification cache (in-kernel)

- **Decision.** The TC programs maintain a `BPF_MAP_TYPE_HASH`
  flow_table keyed by canonical 5-tuple `(min_ip, max_ip, min_port,
  max_port, proto)` so both directions of a TCP/UDP flow share an
  entry. Each entry stores `{state: classifying|classified|unknown,
  classified_as: enum L7Proto, packets, bytes, last_seen_ns,
  packets_observed_for_classification}`. On classification (or after
  the per-flow packet budget exhausts) userspace updates the entry's
  `state` and `classified_as` via a syscall write to the BPF map;
  subsequent packets short-circuit at the TC program and never reach
  userspace. Eviction policy: LRU bounded by a per-interface map
  capacity (default 65,536 flows), plus a periodic userspace sweep
  that ages out entries with `last_seen_ns` older than 5 minutes.
- **Alternatives.** Userspace-only flow cache (rejected; doesn't
  prevent the kernel→user transition); per-CPU maps (rejected for
  simplicity; revisit if contention shows in benchmarks).
- **Rationale.** The single biggest CPU win available; mirrors the
  nDPI flow-cache pattern adapted to the kernel.

### D4d. AF_XDP for new-flow packet delivery

- **Decision.** The first 8–32 packets of each new flow are delivered
  to userspace via an AF_XDP shared ring (configurable
  `XDP_NEW_FLOW_PACKET_BUDGET`, default 16). AF_XDP is preferred over
  perf-event ring buffers for the L7-classification packet path
  because it supports zero-copy and large frame sizes; the perf RB
  remains the right tool for fixed-size structured events (SYN
  signatures, socket-lifecycle events, flow counters). **Userspace
  consumes the AF_XDP ring on a dedicated OS thread per interface,
  pinned via `sched_setaffinity` to a core local to the interface's
  IRQ affinity (NUMA-aware where applicable).** The consumer thread
  runs a busy-poll loop with a short adaptive backoff (default 10 µs
  → 1 ms when idle) and communicates with the tokio main loop via a
  SPSC channel (`flume` or `crossbeam-channel`, implementer's
  choice).
- **Alternatives.** (a) AF_XDP ring polled by a tokio task — rejected
  because tokio's work-stealing scheduler can migrate the task off
  the IRQ-local core, defeating NUMA / L1-L2 cache locality. The
  point of AF_XDP is to bypass the kernel socket layer; bouncing the
  consumer between cores wastes most of that win. (b) Single perf
  ring buffer for both packet data and events — works but loses
  zero-copy and conflates packet-rate pressure with event-rate
  pressure. AF_XDP keeps the two concerns separated.
- **Rationale.** Same pattern Datadog uses for its NPM packet-sample
  path; same pattern Cilium uses for socket-redirect handling. The
  dedicated-OS-thread + CPU-pinning pattern is what makes AF_XDP's
  zero-copy promise actually translate into measured CPU reduction.

### D4e. Runtime model: tokio for control plane, dedicated threads for hot data

- **Decision.** Keep tokio's work-stealing pool for the control plane
  (IPC `accept` loop, `ApplyConfig` request/response, health probe,
  Prometheus metrics endpoint, BPF map allocation, kprobe attachment)
  and use dedicated OS threads with `sched_setaffinity` pinning for
  the latency-sensitive AF_XDP consumers (D4d). Replace
  `tokio::sync::broadcast` for `FingerprintEvent` and `DpiEvent` IPC
  fan-out with per-consumer SPSC channels (`flume` or
  `crossbeam-channel`); the IPC server's single-client gate already
  guarantees one subscriber. Pool the `prost` encode buffer per
  consumer thread so steady-state event encoding produces zero
  allocations after warmup.
- **Alternatives considered — full compio / io_uring migration.**
  iggy-style thread-per-core + completion-based I/O is a clean
  architectural fit for IO-heavy workloads (message brokers,
  log-structured storage) where millions of small reads/writes per
  second amortise the io_uring submission-queue batching benefits.
  netprobe's hot paths are different:
  - AF_XDP rings sidestep both readiness and completion models —
    they're a shared memory ring polled directly via mmap, not driven
    through `read()` / `write()` syscalls. Whether userspace runs a
    tokio runtime or a compio runtime doesn't affect the AF_XDP
    consumer's syscall pattern.
  - BPF map syscalls (`bpf(BPF_MAP_UPDATE_ELEM, ...)`) are not yet
    reachable through io_uring's submission queue (kernel-ABI gap as
    of 6.x). compio cannot accelerate them.
  - UDS writes to the agent at 100–10k events/sec on a typical host
    do not approach the syscall-pressure regime where io_uring
    earns its keep (iggy's workload is several orders of magnitude
    higher).
  - tokio ecosystem compatibility matters: OpenTelemetry context
    propagation, `tonic` if we ever need full gRPC, `hyper` for
    metrics, all assume tokio. compio's ecosystem is smaller.
  - `AsyncWrite` ownership ergonomics: completion-based runtimes
    require buffer ownership / lifetime gymnastics that don't match
    our existing `prost::encode_to_vec` framing layer.

  The thread-per-core *execution* benefits (cache locality, NUMA
  alignment, no work-stealing migration on the hot path) apply to
  AF_XDP consumers and we capture them via D4d's pinned-OS-thread
  decision. The io_uring *I/O model* benefits don't materially apply
  to our syscall mix. Hybrid wins ~80% of the iggy-style architecture
  benefit for ~20% of the migration cost.
- **Rationale.** The two axes — I/O model (readiness vs completion)
  and execution model (work-stealing vs thread-per-core) — are
  orthogonal. Thread-per-core for hot data is the win that matters
  for netprobe; io_uring is overkill at our event rates. If Phase 3
  benchmarks (§18.15) show us bound by runtime overhead rather than
  algorithm cost, revisit the full compio migration as a Phase 7+
  architecture refresh.

### D5. eBPF programs and capability requirements (expanded)

- **Decision (revised 2026-05-27).** `netprobe` loads its full eBPF
  surface via `aya` at startup. The program set covers both the
  continuous capture path (D4) and the process attribution path
  (originally Phase 3-only):

  **Capture path:**
  - `cls_bpf` TC ingress + egress on each allowlisted interface —
    5-tuple parse, flow_table lookup, classified flows: bump
    counters + `TC_ACT_OK`; new flows: insert entry + redirect to
    AF_XDP for first N packets.
  - AF_XDP `XDP_FLAGS_SKB_MODE` ring per interface for L7-dissector
    packet delivery (D4d).

  **Fingerprint path:**
  - `kprobe/tcp_rcv_state_process` (or kernel-version equivalent) —
    extract SYN TCP options (TTL, window, MSS, options layout,
    quirks, ip_version, window_scale, payload_class) at connection
    setup, emit one p0f-signature event per connection. Userspace
    runs the in-tree p0f matcher / OS-match ensemble once per event;
    no per-packet work.

  **Attribution path:**
  - `kprobe/tcp_connect`, `kretprobe/inet_csk_accept`,
    `kprobe/tcp_close` for TCP socket lifecycle.
  - `kprobe/udp_sendmsg` + `kprobe/udp_recvmsg` for UDP.
  - `tracepoint/sock/inet_sock_set_state` as backfill.
  - For QUIC, lifecycle inferred from underlying UDP + DPI (no
    dedicated QUIC kprobe).

  **Maps:**
  - `flow_table` — `(5-tuple) → FlowState` (D4c).
  - `flow_to_pid` — `(5-tuple) → PID` populated by socket-lifecycle
    kprobes.
  - `process_info` — `PID → {comm, cgroup_id, uid}` populated on
    socket events.
  - `interface_allowlist` — `(ifindex) → InterfaceConfig` controlling
    TC program attachment per interface.
  - All maps pinned under `/sys/fs/bpf/serviceradar/netprobe/` with
    `0700` perms so a sidecar restart can reattach to existing
    programs without losing in-flight state.

- **Capability sequence at startup:**
  1. Acquire `CAP_BPF`, `CAP_PERFMON`, `CAP_NET_ADMIN`, `CAP_NET_RAW`.
  2. Verify kernel ≥ 5.8; refuse to start otherwise (D4b).
  3. Load eBPF object, attach TC programs to allowlisted interfaces,
     attach kprobes.
  4. Bind AF_XDP rings; allocate BPF maps.
  5. Bind the UDS listener.
  6. Drop to a non-root UID.
  7. Begin serving the agent.

  Subsequent operations never require any of the original
  capabilities. The Phase 5 remote-capture path retains `CAP_NET_RAW`
  for libpcap session handles.

- **eBPF object build.** Programs live under
  `rust/netprobe/ebpf/` as a separate Cargo crate compiled to BPF
  bytecode via `aya-ebpf`. A Bazel `cargo_build_script` (or
  `aya-build`-driven custom rule) embeds the compiled `.o` blobs
  into the userspace binary. `vmlinux.h` is vendored from the
  earliest supported kernel (5.8) for BTF-CO-RE.

- **Alternatives.**
  - `libbpf-rs` instead of `aya` — equally viable; sticking with
    `aya` keeps the build pure Rust (no C toolchain at build time)
    and simpler musl static link.
  - `CAP_SYS_ADMIN` fallback for old kernels — rejected by policy;
    we require the modern split caps.

- **Rationale.** `aya` is the pure-Rust eBPF path that production
  Datadog and Cilium contemporaries also gravitated toward. Capability
  requirements scoped strictly to the sidecar; the agent never gains
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
  - The legacy `IngestExternalFlows(stream ExternalFlowRecord)` arm is not a
    production attribution dependency and may be retired after persisted config
    compatibility and protobuf field reservation are handled.
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

### D8. Storage: bounded attribution state and in-place OCSF stamping

- **Decision.** Device visibility evidence continues to extend existing maps:
  - `device.os.passive_fingerprint` — `{family, version, confidence,
    source: "serviceradar-license-clean", observed_at}`.
  - `device.metadata.passive_fingerprint` — protocol-specific
    signature payloads keyed by `tcp`, `tls`, `http`, each with
    `observed_at`.
  - `device.metadata.dpi` — per-protocol counters and
    last-observation timestamps (no payloads).
  - `device.metadata.local_processes` — periodic snapshot of
    listening sockets and their owning processes; bounded
    cardinality with LRU eviction.
- Flow attribution uses the dedicated bounded current-state table
  `platform.flow_process_attribution_current`, keyed by the authenticated
  partition and agent context plus tuple/process identity. It is not an
  append-only flow history.
- `ServiceRadar.FlowAttribution.Correlation` joins current attribution state
  with independently ingested `platform.ocsf_network_activity` rows and
  updates the matching OCSF row in place, setting the `event_type` field to
  `"attributed_flow"` and adding attribution context. No `flow.attributed.*`
  subject or second attributed-flow table is part of this path.
- **Alternatives.** (a) An append-only process-attribution event table —
  rejected because unmatched observations need bounded current-state
  retention while the existing OCSF flow row is the durable matched artifact.
- **Rationale.** Bounds unmatched producer state, preserves independently
  ingested flow history, and gives the correlator and UI one canonical matched
  OCSF artifact.

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
- Ash-owned records for invasive operator actions use
  **AshPaperTrail** as the audit source of truth wherever the action
  changes a resource. For this proposal that includes
  `RemotePacketCaptureSession` and the operator-managed capture
  posture records that make packet observation possible
  (`VisibilityProfile` and capture-interface allowlist settings when
  represented as Ash resources).
- Every transition of `RemotePacketCaptureSession.state` is performed
  through Ash actions with AshPaperTrail enabled, so the version trail
  captures request, authorise, start, terminate cause, byte total,
  actor, partition, request id, agent id, target interfaces, and the
  normalized BPF filter metadata needed for investigation.
- Request id is a required Ash action context field for invasive
  operator actions. Do not infer it from `Logger.metadata` or other
  process-local state; missing request id is a validation failure so
  the audit trail cannot silently lose correlation.
- Denials that intentionally do not create a session record (for
  example cross-tenant target attempts) still write a durable audit
  event through the standard audit log capability. That event MUST
  include actor, partition, attempted agent id, requested interface,
  normalized BPF filter metadata, denial reason, and request id.
- Sessions are partition-scoped: a user with the permission in
  tenant A cannot start a capture on tenant B's agent even if the
  agents share a gateway.
- **Alternatives.** None considered — RBAC + audit are mandatory
  for any packet capture surface.
- **Rationale.** Security review will gate this feature on the
  audit trail being complete, implemented through AshPaperTrail where
  resource state changes, and the permission being separately-
  grantable.

### D13. NetFlow to application attribution data flow

- **Decision.** `serviceradar-netprobe` emits local socket/process
  observations to the agent without receiving NetFlow. The agent encodes them
  in `FlowAttributionEventBatch`, retains the ordered pending prefix, and sends
  it through `StreamStatus`. Agent-gateway authenticates the sender and forwards
  the status to core; core uses that authenticated agent/partition context when
  upserting `platform.flow_process_attribution_current`. The CNPG correlator
  joins this state to normal NetFlow/IPFIX rows written independently by
  EventWriter and stamps the existing OCSF row in place as
  `event_type = "attributed_flow"`.
- Agents not running `netprobe` continue using the existing unattributed flow
  pipeline. A netprobe observation with no sampled-flow overlap remains useful
  forensic current state but cannot produce an attributed flow.
- **Alternatives.** (a) Forward per-host NetFlow slices to agents — rejected
  after the demo canary because it requires dynamic per-agent routing and still
  cannot create exporter traffic that was never sampled. (b) Let `netprobe`
  ingest NetFlow directly from switches — rejected because it duplicates
  `flow-collector` and pulls listener concerns into the sidecar.
- **Rationale.** Agent-up observations keep netprobe focused on host-local
  evidence, preserve independent raw flow ingestion, and make missing topology
  overlap observable at the component that owns the join.

### D14. OS fingerprinting technique: license-clean stack (p0f-in-eBPF + JA4 base + HASSH)

- **Decision.** `serviceradar-netprobe` SHALL produce OS / device
  fingerprints using a **license-clean signature stack** with no
  dependency on FoxIO-License-1.1 / patent-pending methods. The stack:

  1. **p0f-canonical TCP fingerprint, computed inside the eBPF
     kprobe.** Primary layer. Covers every observed TCP SYN. The §18.5
     SYN kprobe already extracts TTL / window / MSS / options layout /
     scale / quirks / pclass — exactly the p0f signature inputs.
     Encoding the canonical p0f form (`ver:ttl:olen:mss:wsize,scale:olayout:quirks:pclass`)
     in the kprobe and emitting it via ring buffer means userspace
     never re-parses the packet; the userspace classifier is a
     compile-time `phf::Map<P0fSignatureKey, P0fLabel>` lookup over the
     vendored corpus.
  2. **JA4 (base, TLS ClientHello), computed in userspace.** Secondary
     layer for TLS-visible devices. JA4 base is BSD-3-Clause and
     FoxIO has publicly stated "no patent claims and is not planning
     to pursue patent coverage" for it. Safe for commercial use.
     Computed in userspace from the TLS ClientHello extracted by the
     existing DPI TLS dissector.
  3. **HASSH (SSH KEXINIT), computed in userspace.** Secondary layer
     for SSH-visible devices. BSD-3-Clause via Corelight's maintained
     fork of the Salesforce / Ben Reardon (2018) work, no patent
     issues. Computed in userspace from the SSH KEXINIT field lists
     extracted by the existing DPI SSH dissector.
  4. **In-house ServiceRadar canonical formats (optional, deferred).**
     For TLS-server fingerprinting (the JA4S equivalent), HTTP request
     fingerprinting (the JA4H equivalent), and any other surface
     where we want hashed-field fingerprints, ServiceRadar defines its
     own canonical-string format under our own license. The patent
     claim FoxIO has filed is on the *specific* JA4+ canonical forms;
     a differently-defined canonical hash of the same underlying
     fields is not encumbered. Deferred to a later Phase 2.x
     amendment; not required for the discovery-scope use case.

  The `huginn-net` crate is removed from `netprobe`'s dependency set
  (§31.7). The p0f canonical encoder, the JA4-base encoder, and the
  HASSH encoder are all hand-rolled in-tree.
- **Licensing audit (the reason we do not adopt JA4+).**
  - **JA4 (base, TLS ClientHello)** — BSD-3-Clause. FoxIO explicit
    no-patent stance. **Used.**
  - **JA4T** (TCP) — FoxIO License 1.1, patent pending. The
    monetization clause and patent posture make it incompatible with
    ServiceRadar's commercial sale. **Not used.** p0f is the
    license-clean substitute and our primary need anyway, since
    most fingerprintable traffic crossing the agent host is
    TCP-without-TLS.
  - **JA4H** (HTTP) — FoxIO 1.1, patent pending. **Not used.**
    Replaced by an in-house HTTP canonical format if/when we need
    HTTP fingerprinting (Phase 2.x amendment, optional).
  - **JA4S** (TLS ServerHello) — FoxIO 1.1, patent pending.
    **Not used.** Replaced by an in-house TLS-server canonical
    format if/when needed (Phase 2.x, optional).
  - **JA4SSH** — FoxIO 1.1, patent pending. **Not used.** HASSH
    (BSD-3) is the license-clean substitute.
  - **JA4X** (X.509) — FoxIO 1.1, patent pending. **Not used.**
    Not in scope for our use case.
  - **JA4L / JA4LS** (latency) — FoxIO 1.1, patent pending. **Not
    used.** Not in scope.

  This split is exactly per FoxIO's published licensing terms (JA4
  the base method is open, BSD-3, patent-disclaimed; the rest of the
  JA4+ family requires an OEM license for resale-in-product use).
- **Alternatives considered.**
  - **`huginn-net` + p0f signatures (the original Phase 1 plan).**
    Rejected. huginn-net's API is tightly coupled to its libpcap
    capture loop, which we are eliminating in Phase 3 (§19.1–§19.3).
    We retain the *signature corpus* p0f produced as a separately
    replaceable LGPL-2.1 data file and drop the implementation crate.
    ServiceRadar's in-tree parser is ~300 LOC, single file, zero deps.
  - **Full JA4+ ensemble (JA4T / JA4H / JA4S / JA4SSH).** Rejected
    on licensing grounds. FoxIO License 1.1 prohibits commercial
    use without an OEM license; all methods are patent pending.
    ServiceRadar is a commercial product; the monetization clause
    bites us. The technical benefit over a p0f-in-kernel +
    JA4-base + HASSH stack does not justify either paying FoxIO
    indefinitely or accepting patent exposure.
  - **Datadog NPM / Cisco Secure Workload style: TCP fingerprinting
    in userspace from libpcap.** Rejected. The kernel kprobe already
    sees every TCP SYN at the socket layer; computing the canonical
    fingerprint there saves userspace re-parsing and removes
    `bpf_probe_read_kernel` round-trips. No major NPM vendor does
    p0f-in-kernel today; doing it there is a real differentiator.
  - **Active fingerprinting (Nmap-style OS detection).** Rejected for
    the continuous capture path. Active probing is reserved for the
    `serviceradar-mapper` discovery pipeline; `netprobe` remains a
    passive observer. The two pipelines feed the same
    `IP Alias Resolution`-bound device record.
- **Rationale.**
  - **License-clean for commercial sale.** The executable fingerprint
    stack is in-tree / permissively licensed. The upstream p0f corpus
    is LGPL-2.1 and shipped as a separate replaceable data file with
    its original notice and license preserved. No FoxIO OEM licensing
    required. No FoxIO patent exposure. ServiceRadar can ship, sell,
    and update the fingerprint stack while preserving the p0f corpus's
    LGPL boundary.
  - **TCP is the dominant fingerprintable signal anyway.** The user
    has confirmed the discovery scope is "fingerprint discoverable
    devices for inventory," which is overwhelmingly TCP traffic
    (port scans, discovery probes, network management protocols).
    p0f covers this case fully. TLS/SSH/HTTP fingerprints are
    confidence boosters when applicable, not the primary signal.
  - **p0f-in-eBPF is novel.** Computing the p0f canonical form
    inside a kernel kprobe and matching against a compiled-in
    `phf::Map` of p0f signatures is genuinely new ground. No
    existing tool does this; certainly no commercial NPM vendor
    does. Same architectural win as we'd get with JA4T, without
    the licensing cost.
  - **20 years of p0f signatures.** The LGPL-2.1 `p0f.fp` corpus has
    20 years of fingerprints from across the OS / device spectrum.
    While upstream is effectively frozen, the corpus still covers an
    enormous range, particularly the legacy / embedded gear that
    modern signature databases under-cover. ServiceRadar additions
    land in `serviceradar-additions.fp` over time as we encounter
    signatures upstream lacks.
  - **IPv6 covered.** Modern p0f.fp signatures include IPv6 entries;
    where they don't, ServiceRadar additions can fill the gap. The
    kprobe encodes both IPv4 and IPv6 SYN observations.
  - **JA4 base (BSD-3) gets us modern TLS fingerprinting.** TLS
    libraries are updated about once a year per FoxIO's own
    documentation; JA4 base tracks those changes via community
    contributions. Patent-disclaimed, license-clean, well-maintained.
- **Trade-offs.**
  - **No JA4T → OS lookup table.** We don't get to use the
    FoxIO-curated JA4T → OS database. p0f.fp is our substitute;
    coverage shape is different (broader for legacy, narrower for
    fine-grained modern OS-version discrimination). Acceptable for
    the inventory-discovery use case.
  - **In-house TLS-server / HTTP fingerprints are deferred.** If we
    decide later that the JA4S / JA4H equivalents matter for
    confidence boosting, we have to design + implement our own
    canonical formats under our own license. Not free, but not
    blocking Phase 1 either.
  - **Upstream p0f corpus is frozen.** Net-new signatures land in
    `serviceradar-additions.fp` — that's a maintenance burden we
    carry rather than upstream. Acceptable; the format is simple
    and additions are low-effort.
- **Implementation surface.** Phase 1 amendment §31 in `tasks.md`
  lays out the work: p0f corpus vendoring, the `#![no_std]` p0f
  canonical encoder for the kprobe, the userspace JA4-base encoder,
  the userspace HASSH encoder, the ensemble matcher (p0f primary,
  JA4 / HASSH as confidence boosters), proto-schema migration of
  `FingerprintEvent`, removal of `huginn-net` from `Cargo.toml`,
  rewrite of §18.10 onto the p0f lookup table, and the curation
  workflow for `serviceradar-additions.fp`.

### D15. Multi-corpus fingerprint ensemble (MuonFP + Recog + Satori)

- **Decision.** D14's license-clean stack (p0f + JA4-base + HASSH) is
  the *foundation*. Layered on top of it, `serviceradar-netprobe`
  SHALL incorporate three additional corpora to
  expand fingerprint coverage by an order of magnitude:

  1. **MuonFP** (Censys, MIT) — a second TCP SYN fingerprint matcher,
     **parallel** to p0f (not a replacement). Modern corpus actively
     maintained against current OS releases; complements p0f's
     legacy-strong / modern-thin coverage shape.
  2. **Recog** (Rapid7, BSD-2-Clause-Views) — 4,712 banner /
     service-string fingerprints. Pattern-matched against output of
     the existing DPI dissectors: HTTP `Server:` header, SSH banner,
     FTP / Telnet / SMB / SNMP / SIP / RDP / DNS banner strings. Each
     fingerprint maps to OS / vendor / product / version. This is the
     single biggest corpus addition and the dominant accuracy lever.
  3. **Satori XML corpus** (xnih/satori, GPLv2) — ~1,980
     multi-protocol fingerprints shipped as a separate replaceable data
     corpus under `rust/netprobe/satori-corpus/`. Pattern-matched
     against TCP SYN signatures plus observable DPI surfaces:
     DHCP/DHCPv6, DNS, SMB browser / SMB, SSH, SSL/TLS fingerprints,
     HTTP server, browser user-agent, ICMP, NTP, and SIP. Only the XML
     database files are vendored; the Python runtime, pcap code, and
     SSL/JA4 implementation are not used.

  The ensemble matcher fuses all observable axes — TCP SYN, TLS
  ClientHello, SSH KEXINIT, HTTP banner, SSH banner, SMB / FTP /
  Telnet / SNMP banners, DHCP options — into one `OsMatch` per
  device, with confidence weighted by *corpus agreement count*. A
  device producing matching p0f + MuonFP + Recog-HTTP + JA4 all
  agreeing on `Ubuntu 22.04` gets the highest confidence tier; a
  device producing only p0f gets the lowest.

  Combined audited corpus reach: ~7,000 fingerprints across
  ~8 independent observation axes. For context, huginn-net's p0f-only
  reach is ~400. This is the "big database" direction.
- **License audit of the new corpora.**
  - **MuonFP** — MIT, Censys publicly ships it without a FoxIO OEM
    agreement (so far as is externally visible). We adopt it under
    MIT and document the assumption that Censys's posture covers
    derivative commercial use. Quarterly licensing review per the
    §31.13 CI lint.
  - **Recog** — BSD-2-Clause-Views (Rapid7's modified BSD-2 retaining
    Rapid7 attribution requirements). Permissive for commercial use;
    requires LICENSE / NOTICE preservation. Used by Metasploit Pro
    and InsightVM commercially, so the licensing is well-tested at
    Rapid7's own commercial scale.
  - **Satori XML corpus** — GPLv2 at the maintained
    `https://github.com/xnih/satori` upstream. ServiceRadar vendors only
    `fingerprints/*.xml`, plus the upstream README and GPLv2 license
    text, as a separate replaceable data corpus. ServiceRadar
    parser/matcher code is independently authored and remains
    Apache-2.0. Any ServiceRadar-authored additions must live in
    separate files under ServiceRadar's license rather than modifying
    upstream GPLv2 XML in place.
- **Alternatives considered (and rejected).**
  - **Nmap `nmap-os-db`** (~6,000 active OS fingerprints). Rejected
    on licensing grounds. Nmap Public Source License is a modified
    GPLv2 with redistribution restrictions; not commercial-compatible.
    Rapid7 fought this exact battle over Metasploit's Nmap bundling
    in 2009 and lost. Do not bundle.
  - **Fingerbank** (Akamai / Inverse, ~50k+ DHCP/MAC fingerprints).
    Rejected on licensing grounds. Free tier non-commercial only;
    commercial use requires paid API key, which doesn't fit our
    embedded-in-the-product model. Satori covers the DHCP axis under a
    GPLv2 data-corpus model at smaller but adequate scale.
  - **PRADS** signature DB. Rejected — GPLv2 viral.
  - **Shodan corpus.** Rejected — closed commercial.
- **Rationale.**
  - **Corpus size is the dominant accuracy lever.** Going from ~400
    signatures (huginn-net's p0f) to ~7,000 across multiple axes is
    a far bigger accuracy win than any algorithmic improvement we can
    make to a single canonical-form encoder.
  - **Independent axes shrink false positives.** Three corpora
    matching the same OS family with three different observable
    surfaces (TCP + HTTP banner + SSH banner) yields far higher
    confidence than three different signatures over the same
    surface. The ensemble explicitly rewards cross-axis agreement.
  - **All three corpora are actively maintained.** Recog merges
    Rapid7's research output, Satori tracks current device releases,
    MuonFP tracks modern OSes — together they keep ServiceRadar's
    fingerprint surface current without huginn-net's frozen-2014
    baggage.
  - **No new packet-capture surface required for Recog.** The Phase 2
    DPI dissectors (HTTP, TLS, SSH, FTP, etc.) already extract the
    banner strings Recog patterns match against. The integration is
    "consume what we already see" — Recog matchers fire from the
    dissector callbacks, no additional kernel work.
- **Trade-offs.**
  - **Recog XML format requires a parser.** The Recog corpus is XML
    with embedded regex patterns. ~400 LOC Rust using `quick-xml`,
    with compile-time regex codegen via `regex-automata` so runtime
    matching is allocation-free finite-automata work. Build-time
    cost: ~30s incremental rebuild on a typical dev machine when the
    corpus version changes.
  - **Satori is GPLv2 data.** The Satori corpus is shipped with GPLv2
    notices and its preferred-source XML intact. Operators can replace
    the XML files. ServiceRadar code must treat the corpus as data and
    must not copy or translate the Python implementation.
  - **Some Satori axes are topology-bounded.** DHCP only fires when the
    agent sees DHCP traffic, which means the agent must be on the same
    broadcast domain as the device being discovered (or sitting behind a
    DHCP relay that mirrors traffic). Other Satori axes (TCP, HTTP, SSH,
    SMB, TLS, DNS, NTP, SIP, ICMP) fire only when those protocol
    observations are present in the existing DPI / eBPF surfaces.
    UI surfaces per-axis observation flags so operators know which
    corpus axes were active for a device.
  - **Binary size impact.** Compiled Recog (4,712 regex patterns into
    `regex-automata` DFAs) adds ~2-4 MiB to the static musl binary.
    p0f + MuonFP add another small compiled footprint. Satori's GPLv2
    XML remains runtime-loaded from a separately replaceable data
    directory, so it affects package size rather than the default binary
    image. Total compiled fingerprint surface adds ~4-6 MiB. Acceptable
    on agents running on 4+ GB hosts; flagged in the §32 validation gate
    so we catch if compression / DFA-minimization options become
    available.
  - **Recog upstream cadence.** Rapid7 ships Recog updates roughly
    monthly. We track an upstream pinned release and bump it
    quarterly; net-new ServiceRadar additions land in
    `serviceradar-recog-additions.xml` between bumps.
- **Implementation surface.** Phase 1 amendment §32 in `tasks.md`
  lays out the work: vendor MuonFP / Recog / Satori corpora, build
  the Recog XML → compile-time regex-DFA codegen, build the Satori
  XML parser / matcher, add a Phase-2 DHCP DPI dissector (~150 LOC) for
  the Satori DHCP axis, wire Satori's TCP XML to the same SYN data used
  by p0f / MuonFP, wire the Satori banner/protocol XML to existing DPI
  callbacks, wire MuonFP into the kprobe as a parallel TCP signature,
  extend the §31.9 ensemble matcher to fuse all axes,
  extend the `LicenseCleanFingerprint` proto to carry the additional
  match labels, extend `PingAck` to report all corpus revisions, and
  extend the §31.13 CI license-lint with an allowlist that catches
  unauthorized corpus additions and compile-time embedding of the GPLv2
  Satori XML corpus.

### D16. Active banner-grab phase in the sweep service

- **Decision.** ServiceRadar SHALL add a new **active banner-grab
  phase** to the existing **sweep service** (`go/pkg/scan/`,
  not the SNMP/API-focused mapper at `go/pkg/mapper/`). The phase
  runs immediately after the existing SYN half-open scanner
  (`go/pkg/scan/syn_scanner.go`) identifies live `(host, port)`
  pairs, against those confirmed-live targets only, opt-in per
  `SweepProfile`.

  For each selected `(host, port)`, the phase opens a full 3-way TCP
  connect, sends a protocol-appropriate probe if needed, reads up to
  `max_banner_bytes` of cleartext or pre-auth response payload, closes
  the connection, and emits a
  `BannerObservation { host, port, protocol, banner_bytes, observed_at,
  source = sweep_active }` record. The
  agent forwards successful observations to the running `netprobe`
  sidecar over the existing UDS via a new batched IPC method
  `MatchBanners(BannerBatch) → BannerMatchBatch`. Netprobe runs the
  §32 Recog and Satori matchers against the supplied observation bytes
  and returns matched labels. The agent then emits / forwards the
  resulting `FingerprintEvent` records tagged with
  `source = sweep_active` through the normal discovery ingestion path —
  `DeviceDiscoveryIngestor` (Elixir) joins them to the canonical device
  via `IP Alias Resolution`.

  This is a direct application-layer handoff, not a passive-sniffing
  contract. Netprobe's eBPF programs may also observe the sweep
  service's sockets, but passive observation is not sufficient for
  active banner-grab classification: direct handoff avoids ambiguous
  correlation between a locally-originated sweep socket and the intended
  target record. HTTPS/TLS fingerprinting is handled by the passive
  TLS/SSL fingerprint pipeline, not by decrypting HTTPS responses in
  banner grab.

  All fingerprint matching stays in netprobe (Rust); the corpus stays
  in `rust/netprobe/` per §32. No corpus duplication, no shared
  Rust/Go crate, no cgo. Mapper and the SNMP polling code are
  unaffected — the new phase is additive to sweep only.
- **Integration contract.**
  - **Go sweep service:** consumes SYN / ICMP sweep results, selects
    allowlisted live `(host, port)` candidates, opens outbound TCP
    sockets, sends protocol probes, reads cleartext / pre-auth banners,
    enforces concurrency / rate / timeout controls, and batches
    `BannerObservation` records to netprobe.
  - **Rust netprobe passive path:** eBPF / AF_XDP observes packet-level
    evidence generated by any traffic on allowlisted interfaces,
    including sweep-generated traffic. This path owns p0f / MuonFP /
    Satori-TCP / JA4 / HASSH / TLS-style packet fingerprints where the
    required fields are visible on the wire.
  - **Rust netprobe banner-match path:** `MatchBanners` accepts the
    application bytes Go already assembled from active probes and
    matches them against Recog / Satori banner axes. It does not open
    outbound sockets and does not need to reconstruct these banners from
    passive packet capture.
  - **Agent ingestion path:** the agent converts banner matches and
    passive fingerprint events into the same discovery enrichment stream
    so core receives compact labels, not raw banner payloads.
- **Large-inventory performance model.** Banner grab is a **streaming
  enrichment pipeline**, not a second in-memory inventory build. The
  SYN half-open scanner remains the only subnet-wide fast path; banner
  grab consumes SYN-confirmed open `(host, port)` candidates as a
  bounded stream and may process every eligible candidate in a cycle if
  the operator chooses to pay the time / traffic cost. The safety
  contract is bounded resource usage, not an artificial completeness
  cap.

  The scheduler MUST apply all of the following before or during 3-way
  connects:
  1. **Candidate gate.** Drop candidates whose port is not in the
     active profile's banner-grab allowlist.
  2. **Freshness gate.** Skip candidates whose previous banner result
     is still fresh. Default `min_reprobe_interval_s = 86400`
     (24 hours), with operator-triggered refresh able to bypass it.
  3. **Error backoff.** Skip candidates that recently produced
     connection reset, timeout, or empty-response outcomes until their
     per-target backoff expires.
  4. **Bounded in-flight work.** Keep candidate queues, active socket
     count, pending netprobe-match batches, and result buffers bounded by
     configuration. The implementation MUST NOT materialize a 1M-host
     banner-grab worklist in memory.
  5. **Throughput controls.** Enforce `max_global_concurrency`,
     `max_concurrency_per_host`, `per_host_rate_limit_ms`, and optional
     `max_probe_rate_per_second` as operational controls. These controls
     shape resource use; they do not silently drop eligible candidates.
  6. **Batched Rust matching.** Accumulate successful observations into
     bounded batches (default target 256 observations or 1 MiB, whichever
     comes first) before invoking `MatchBanners` on netprobe. This avoids
     one UDS round trip per banner at million-host scale while keeping
     raw banner bytes local to the agent host.
  7. **Checkpointable progress.** Track the phase cursor / counters so a
     long large-inventory banner-grab can report progress and resume or
     continue on the next cycle without starting from scratch after an
     agent restart.

  This keeps the customer-visible SYN reachability path fast while still
  allowing exhaustive banner grabbing at 20k, 100k, or 1M-host scale.
  The price of exhaustive active probing is elapsed time and outbound
  connection volume, not unbounded agent memory, goroutines, sockets, or
  Rust IPC requests.
- **Go TCP-connect performance audit.** Banner grab depends on the
  Go agent's full-connect behaviour, so the current TCP connect path
  MUST be measured before the banner-grab phase is enabled at fleet
  scale. The existing `go/pkg/scan/tcp_scanner.go` implementation is a
  fixed worker pool around `net.Dialer.DialContext` with a default
  5-second timeout and 500-worker concurrency. That is materially better
  than the historical low-concurrency path, but the scanner still exposes
  a slice-based `Scan(ctx, []Target)` API, buffers results to
  `len(tcpTargets)`, and lacks a 50k / 1M-target benchmark proving that
  target generation, result buffering, goroutine count, file descriptor
  pressure, ephemeral-port pressure, timeout distribution, and retry /
  backoff behaviour stay bounded.

  Before §33 wires banner grabbing into the sweep service, the Go side
  MUST add a benchmark and tuning pass for full TCP connects. The pass
  should compare the historical configuration that produced multi-hour
  50k-host scans against the current defaults and the banner-grab
  defaults, using a deterministic fake dialer or loopback harness so CI
  does not require a real 50k-host network. The desired shape is a
  streaming full-connect engine whose memory is O(concurrency + bounded
  queues + batch size), not O(total candidates), with concurrency and
  start-rate caps derived from operator config and clamped by observed
  host limits such as `ulimit -n` and the ephemeral port range when those
  limits are available. Telemetry should expose active dials, dial start
  rate, queue depth, timeout count, reset count, and resource-exhaustion
  errors so operators can tune profiles instead of rediscovering the old
  19-hour failure mode in production.
- **Why sweep, not mapper.**
  - The user's "lightning-fast TCP SYN half-open scanner" is in
    `go/pkg/scan/syn_scanner.go`, used by the **sweep service**.
    `go/pkg/mapper/` does SNMP / API / topology discovery against
    *already-known* device IPs, not subnet-wide port discovery.
  - The banner-grab phase consumes SYN-scan output (live
    `(host, port)` pairs). That output is produced by sweep, not
    mapper. Coupling banner grab to sweep keeps the dependency
    direction sane.
  - Mapper's SNMP `sysDescr.0` collection already provides an OS hint
    for SNMP-reachable devices; banner grab fills the gap for devices
    that don't speak SNMP but do expose a TCP service (Windows
    workstations, IoT appliances, application servers, network gear
    without SNMP enabled).
- **Why active probing alongside passive observation.**
  - Passive observation in netprobe only sees banners from devices
    that *already* send traffic across the agent NIC. For LAN
    inventory discovery, most target devices never talk to the agent
    host; their banners are never observed passively. Recog's audited
    4,712 banner-axis fingerprints (per §32) stay dormant without
    an active path.
  - The active banner-grab phase deliberately triggers cleartext or
    pre-auth responses from confirmed-live devices and routes those
    responses through the agent's discovery pipeline. TLS/SSL evidence
    stays in the passive fingerprint pipeline; banner grab does not
    decrypt HTTPS.
  - Together they form a discovery-axis ensemble: SYN scan
    (reachability) + banner grab (application-layer fingerprint) +
    passive observation (everything else that happens to cross the
    NIC) + SNMP/API (for managed devices) feed the same canonical
    device record.
- **TLS / HTTPS boundary.** HTTPS is out of scope for the banner-grab
  phase. Recog and Satori TLS/SSL axes are fed by the existing
  TLS/JA4-style observation path (§31/§32), not by an active
  `HEAD /` over TLS probe. This keeps §33 focused on banner protocols
  whose identifying material is visible in cleartext or as a pre-auth
  protocol response.
- **Per-protocol probe modules.** Implemented in
  `go/pkg/scan/banner_grab/<protocol>.go`. Each module exports a
  function with the signature
  `Probe(ctx, host, port, opts) (BannerObservation, error)`.
  Phase-1 protocol set:
  | Protocol | Default ports | Probe behaviour |
  |---|---|---|
  | SSH | 22 | Connect, read first 256 bytes (server sends banner first) |
  | HTTP | 80, 8080, 8000, 8888 | Connect, send `HEAD /`, read response headers |
  | SMB | 445 | Connect, send NEGOTIATE PROTOCOL request |
  | FTP | 21 | Connect, read first 256 bytes (banner sent first) |
  | Telnet | 23 | Connect, read first 256 bytes |
  | SMTP | 25, 587 | Connect, read first 256 bytes (banner sent first) |
  | NTP | 123/UDP | Send mode-6 readvar, read response |
  | DNS-version | 53/TCP | Query `version.bind` CHAOS TXT |
  | RDP | 3389 | Send X.224 connection request, capture response |
- **Out of scope for Phase-1 banner grab.**
  - SNMP community-string probing (already covered by mapper's
    credentialed SNMP poll path).
  - IPMI, Redfish, or any other credentialed probe surface.
  - Aggressive port-scan modes (scan-all-1-65535-then-banner-every-hit).
    The phase only probes ports the profile explicitly lists.
- **Alternatives considered (and rejected).**
  - **Banner grab in mapper.** Rejected. Mapper does
    SNMP/API/topology against known devices; sweep produces the
    live `(host, port)` set the banner-grab phase consumes. Putting
    banner grab in mapper inverts the dependency direction.
  - **Banner grab in netprobe (Rust).** Rejected. Netprobe is a
    passive observer + IPC matcher; making it open outbound TCP
    connections would conflate two roles and require new
    capabilities (outbound TCP from a sidecar that today only
    listens and observes). Sweep already does outbound TCP for the
    SYN scan; banner grab is the natural extension of that surface.
  - **Cross-language regex codegen (emit both Rust and Go Recog
    matchers from a shared corpus).** Rejected. Each Recog rebuild
    would have to regenerate two matcher trees; CI cost roughly
    doubles. The new `MatchBanners` IPC method on netprobe amortizes
    UDS overhead across bounded batches and leaves the corpus as a
    single source of truth in `rust/netprobe/`.
  - **Send raw banner bytes to core-elx for matching there.**
    Rejected. Core-elx already has plenty of work; the agent has
    netprobe running on it with the corpus already; matching at
    the agent edge is cheaper and faster, and the agent → gateway
    payload stays compact (matched labels, not raw banner bytes).
- **Trade-offs.**
  - **IDS / IPS visibility.** A 3-way connect-then-disconnect to a
    closed-after-banner port looks like a port scan to host-based
    monitoring. Operators may need to whitelist the agent's source
    IP in their security tooling. Documented in the operator
    runbook.
  - **Some devices reset on unauthenticated probes.** Treat
    connection reset, read timeout, or partial banner as "no
    banner" rather than scan failure; do not retry aggressively.
  - **Handshake cost at fleet scale.** A full TCP connect consumes
    target accept-queue capacity, agent ephemeral ports, kernel socket
    memory, IDS / IPS attention, and wall-clock time. Even with
    256-way concurrency, probing 100k hosts can become seconds to
    minutes of active traffic depending on timeout behaviour. The
    scheduler's freshness gate, bounded queues, concurrency controls,
    and optional rate controls are mandatory guardrails, not tuning
    niceties.
  - **Audit-trail volume.** Per-probe AshPaperTrail entries would be
    explosive on large inventories. Audit is per-sweep-job, not
    per-probe, to keep volume sane — individual probes log via the
    structured logger at info level, aggregate counts roll into the
    per-job AshPaperTrail entry.
- **Operator UX.** The `SweepProfile` editor (web-ng) gains a new
  "Banner grab" section: enable toggle, protocol checkboxes, per-protocol
  port lists, timeouts, max_banner_bytes, concurrency caps, optional
  probe-rate limit, batch size, queue bounds, and re-probe interval.
  Disabled by default. A "preview" panel shows the estimated outbound
  connection volume and expected elapsed time for the current inventory
  under the configured concurrency / timeout settings.
- **Capability advertisement.** Agent advertises
  `sweep.banner_grab = available` when (a) sweep profile has the
  banner_grab toggle on, (b) netprobe is running and healthy, and
  (c) netprobe reports the §32 Recog corpus is loaded.
  Otherwise `sweep.banner_grab = unavailable` with reason.
- **Implementation surface.** Phase 1 amendment §33 in `tasks.md`
  lays out the work: extend `SweepProfile` Ash resource, plumb new
  fields through Elixir compiler → gateway config → Go parser,
  implement the banner-grab phase in `go/pkg/scan/banner_grab/`,
  per-protocol probe modules, the new `MatchBanners` IPC method on
  netprobe, rate-limit + concurrency caps, audit + RBAC, web-ng UI
  extension, and validation gate.

## Risks / Trade-offs

| Risk | Mitigation |
|---|---|
| eBPF program compatibility across kernels. | Target a minimum kernel of 5.8; degrade gracefully (DPI + fingerprint without process attribution) on older kernels; surface kernel version + program-load failures in agent status. |
| Fingerprint dependency drift into encumbered crates. | CI license lint rejects `huginn-net`, JA4+ family crates, and FoxIO-1.1 dependency drift. |
| `aya` upstream churn (still pre-1.0). | Pin to a tested release and budget for periodic version bumps; document this in the runbook. |
| Sidecar crash storms (e.g. malformed packet bug). | Exponential restart back-off, circuit-breaker, surface as agent health warning. |
| Static musl build pulls in conflicting C-deps. | Validated in Phase 1 by `bazel build --platforms=...linux-musl`; Phase 1 shipping packages use the libpcap-enabled dynamic Linux build with explicit runtime dependencies until static packet capture support is available. |
| Process-attribution cardinality explosion on busy hosts. | Bounded LRU eviction, per-(pid, 5-tuple) deduplication window, sample-interval rate limit per profile, drop counters surfaced as metrics. |
| Privacy: cmdline / DNS leakage. | Default redaction at the sidecar boundary; opt-in via profile flag; clear runbook. |
| Capability creep on the agent process. | All eBPF and pcap capabilities scoped to the sidecar binary via file capabilities or per-process `securityContext`. |
| Overlap with `add-unifi-wifi-discovery-parity` enrichment rules. | Both feed the existing rule matcher; precedence handled by `Classification Provenance`. |
| Operator confusion between per-device fingerprint signals (remote endpoints observed on wire) and host attribution (local processes on agent host). | UI distinguishes "Network Visibility" (about the device being viewed) from "Process Listeners" (about the agent host) on Device Detail. |
| Multi-tenant leakage. | Profiles are partition-scoped Ash resources; agent-gateway authenticates the sender, core derives agent/partition authority from that status context rather than payload claims, and both current-state persistence and OCSF correlation are partition-scoped. |
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

1. **Phase 1 — OS fingerprinting only.** `rust/netprobe` skeleton +
   license-clean p0f / JA4-base / HASSH fingerprinting; static musl
   build targets + libpcap-enabled dynamic Linux agent packaging;
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
4. **Phase 4 — NetFlow to application attribution.**
   Agent-up local observation persistence; protocol-aware core-side CNPG
   correlation; `attributed_flow` stamping; Attributed Flows view. The retired
   demo host-slice canary is not production architecture.
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
5. **macOS / Windows agent.** Initial scope ships netprobe only on
   Linux. Non-Linux agents advertise `host-network-visibility` as
   unavailable. Confirm acceptable.
6. **Long-term packet export (Wireshark `extcap` integration).**
   `srctl capture` pipes pcapng to stdout in Phase 5, which already
   works with `wireshark -k -i -`. A native Wireshark `extcap`
   plugin so engineers can pick a ServiceRadar agent from the
   Wireshark capture-source picker is a follow-up.
7. **Tenant cap ceilings.** What are the right default tenant-level
   maxima for `duration_s`, `byte_cap`, and concurrent sessions?
   Phase 5 defaults (60 s / 50 MiB / 1) are intentionally
   conservative. Confirm with security review before raising.
8. **Capture data staging.** Should `core-elx` *optionally* stage
   completed captures into object storage for asynchronous
   retrieval (`srctl capture history`)? Defaults: no staging,
   captures flow through `core-elx` only as live bytes. Revisit
   when operators ask.
9. **Audit detail level.** Do we record the BPF filter verbatim in
    the audit log, or hash + summarise? Verbatim is operator-
    friendly but a BPF filter can encode IP allowlists. Lean
    verbatim with a redaction hook; confirm with security review.
10. **Skipping `core-elx` on the user-facing leg.** ServiceRadar
    has a precedent for `web-ng` dispatching straight to
    `agent-gateway` when a request does not need core-side
    processing. Remote capture *does* need core-side processing
    (RBAC, audit, session record, tenant cap enforcement), so this
    proposal puts `core-elx` in the path. Revisit if a future
    iteration moves session bookkeeping into `web-ng` or
    `agent-gateway` directly.
