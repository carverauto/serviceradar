# Tasks

Tasks are grouped into the **six phases** defined in `proposal.md` and
`design.md`. Only Phase 1 ships in the first increment of this change;
later phases will be picked up as separate implementation tranches once
Phase 1 is in production. Each section header carries the phase it
belongs to; within a phase, tasks are ordered roughly by dependency.

## Phase 1 — OS fingerprinting only

### 1. [Phase 1] Bazel and Rust workspace plumbing

- [x] 1.1 Add `"rust/netprobe"` to the workspace `members` list in `/Cargo.toml`.
- [x] 1.2 Add `x86_64-unknown-linux-musl` and `aarch64-unknown-linux-musl` to `rust.toolchain(extra_target_triples=[…])` in `MODULE.bazel`.
- [x] 1.3 Add musl linker entries (`x86_64-linux-musl-gcc`, `aarch64-linux-musl-gcc`) to `.cargo/config.toml`; document host-side musl cross-toolchain requirements in `BUILD.md`.
- [x] 1.4 Add `huginn-net`, `tokio`, `prost`, `pcap`, `etherparse`, `nix` to `rust/netprobe/Cargo.toml` (Phase-1 dependency set only; eBPF / DPI crates land with their phases). Regenerate crate-universe via `bazel mod tidy`.
- [x] 1.5 Verify `bazel build //rust/netprobe:netprobe` succeeds with the default platform.
- [ ] 1.6 Verify `bazel build --platforms=//build/platforms:linux_x86_64_musl //rust/netprobe:netprobe` produces a static binary (`file` reports "statically linked", `ldd` says "not a dynamic executable").
- [ ] 1.7 Add a CI matrix entry in `.forgejo/workflows/main.yml` for the musl static build (x86_64 + aarch64).
- [x] 1.8 Define Bazel platforms `//build/platforms:linux_x86_64_musl` and `:linux_aarch64_musl` if not already present.

### 2. [Phase 1] `netprobe` Rust crate — skeleton + lifecycle

- [x] 2.1 Scaffold `rust/netprobe/Cargo.toml` (`name = "serviceradar-netprobe"`, `edition = "2021"`, Apache-2.0) and `rust/netprobe/BUILD.bazel` mirroring `rust/trapd/BUILD.bazel`.
- [x] 2.2 Implement `main.rs` with a `tokio` runtime, CLI flags `--socket`, `--config`, `--log-format`, `--health-port` (Phase 1 omits `--bpf-pin-dir`).
- [x] 2.3 Implement Unix-domain-socket server accepting a single agent client; reject concurrent clients.
- [x] 2.4 Implement length-prefixed protobuf framing per `proto/agent/netprobe/v1/netprobe.proto`.
- [x] 2.5 Implement `Ping`/`PingAck` and graceful shutdown on `SIGTERM` (flush events, close UDS, exit within 5 s).
- [ ] 2.6 Implement capability sequencing for Phase 1: assert `CAP_NET_RAW` at start (already available from systemd / pod securityContext); open pcap handles; drop to a non-root UID before serving UDS. `CAP_BPF` / `CAP_PERFMON` assertions land with Phase 3.
- [x] 2.7 Implement the capture-interface allowlist enforcement (refuse `any`, refuse wildcards, refuse not-in-list interfaces).
- [x] 2.8 Expose Prometheus metrics on a localhost-only HTTP endpoint: `_packets_processed_total`, `_packets_dropped_total`, `_events_emitted_total{stream="fingerprint"}`, `_signature_failures_total`, `_uptime_seconds`.
- [ ] 2.9 Unit tests for framing, UDS lifecycle, capability sequencing, allowlist enforcement.

### 3. [Phase 1] `netprobe` — passive fingerprinting

- [ ] 3.1 Integrate `huginn-net` for TCP p0f-style analysis on the configured capture interfaces.
- [ ] 3.2 Integrate TLS JA4 / JA4S extraction.
- [ ] 3.3 Integrate HTTP header signature extraction limited to non-payload headers (`Server`, `User-Agent`, `Accept-Language`).
- [ ] 3.4 Implement per-(IP, protocol) sample-interval rate limiting honouring `sample_interval_ms`.
- [ ] 3.5 Emit `FingerprintEvent` records on the dedicated server-streamed channel.
- [ ] 3.6 Unit tests with pcap fixtures producing each event variant.
- [ ] 3.7 Integration test (`#[tokio::test]`) running the sidecar end-to-end against fixture traffic.

### 4. [Phase 1] IPC protocol skeleton (`proto/agent/netprobe/v1/`)

- [x] 4.1 Create `proto/agent/netprobe/v1/netprobe.proto` with messages `VisibilityAgentConfig`, `DeviceBinding`, `FingerprintEvent` (oneof TCP/TLS/HTTP), `Ping`, `PingAck`. Reserve field numbers and message names for `DpiEvent`, `FlowAttributionEvent`, `ProcessSnapshot`, `ExternalFlowRecord`, `StartRemoteCapture`, `PcapngBlock` — defined as empty placeholder messages with TODO comments so later phases extend without breaking changes.
- [ ] 4.2 Add `buf` lint pass; no breaking-change checks yet (v1 alpha until first archive).
- [ ] 4.3 Generate Go bindings under `go/proto/agent/netprobe/v1/` and Rust bindings under `rust/netprobe/src/proto/`.
- [x] 4.4 Document framing rules: 4-byte big-endian length prefix, max frame size 4 MiB.

### 5. [Phase 1] Agent sidecar runtime (`go/pkg/agent/sidecar/`)

- [ ] 5.1 Create `manager.go` defining `Manager` that owns `[]Sidecar`, exposes `Start(ctx)` / `Stop(ctx)`.
- [ ] 5.2 Define `Sidecar` interface: `Name()`, `BinaryPath()`, `Args(socketPath, configPath string) []string`, `OnHealthy(client)`, `OnUnhealthy(err)`.
- [ ] 5.3 Implement process supervision via `exec.CommandContext`, structured logger passthrough tagged `sidecar=<name>` + `pid=<pid>`.
- [ ] 5.4 Implement exponential restart back-off (1s → 60s cap); per-minute restart-cap circuit breaker.
- [ ] 5.5 Implement health probe loop (5 s default); mark unhealthy after 3 consecutive failures.
- [ ] 5.6 Surface sidecar state into `StatusResponse` (`name`, `state`, `pid`, `last_health_at`, `restart_count`, `last_error`).
- [ ] 5.7 Implement graceful shutdown: SIGTERM → 5 s grace → SIGKILL.
- [ ] 5.8 Unit-test the manager with a fake `Sidecar` and a fake child script.
- [ ] 5.9 README at `go/pkg/agent/sidecar/README.md` documenting the contract for future sidecars.

### 6. [Phase 1] `netprobe` Go bridge (`go/pkg/agent/netprobe/`)

- [ ] 6.1 Implement a `Sidecar` for `netprobe` plugged into the runtime from §5.
- [ ] 6.2 Implement the IPC client: opens UDS, sends `ApplyConfig`, drains the `FingerprintEvents` stream.
- [ ] 6.3 Translate `FingerprintEvent` records into discovery ingestion records bound to canonical devices via `IP Alias Resolution`.
- [ ] 6.4 Backpressure: drop new events when downstream is slow; increment `_events_dropped_total{stream="fingerprint",reason="backpressure"}`.
- [ ] 6.5 Unit tests for the fingerprint translation path.

### 7. [Phase 1] Agent config delivery

- [ ] 7.1 Extend `proto/monitoring.proto` `AgentConfigResponse` with `VisibilityConfig visibility_config` (parallel to `sysmon_config` / `snmp_config`).
- [ ] 7.2 Define `VisibilityConfig`: `enabled`, `capture_interfaces`, `binary_overrides {path}`, repeated `device_bindings {ip, profile_id, profile_name, fingerprint, sample_interval_ms}`. Reserve fields for `dpi`, `flow_attribution`, `process_snapshot_interval_s` so later phases extend without breaking changes.
- [ ] 7.3 Plumb the new field through Elixir compiler output and Go parser.
- [ ] 7.4 Verify chunked delivery (`add-streamed-agent-config`) handles the new field; add a streaming test case with 5k device bindings.
- [ ] 7.5 Hash the new sub-config into the agent's config version hash.

### 8. [Phase 1] Ash control plane (`elixir/serviceradar_core/`)

- [ ] 8.1 Create `lib/serviceradar/inventory/visibility_profile.ex` Ash resource. Phase 1 attribute set: `name`, `description`, `enabled`, `target_query`, `priority`, `fingerprint {tcp, tls, http}`, `sample_interval_ms`, `retention_days`, `partition_id`, temporal fields. Add the remaining maps (`dpi`, `flow_attribution`, `process_snapshot_interval_s`) as nullable so they can be populated by later phases without another migration.
- [ ] 8.2 Generate migration via `mix ash.codegen add_visibility_profile`; apply with `mix ash.migrate`.
- [ ] 8.3 Add `Ash.Policy.Authorizer` policies mirroring `SysmonProfile`.
- [ ] 8.4 Create `lib/serviceradar/agent_config/compilers/visibility_compiler.ex` using `SrqlTargetResolver.resolve_for_device/2`. Compile only the fingerprint surface in Phase 1.
- [ ] 8.5 Unit tests for compiler: priority ordering, default scope `in:devices`, disabled profile handling.
- [ ] 8.6 Wire compiler output into `AgentConfigResponse.visibility_config`.
- [ ] 8.7 Extend `Serviceradar.Inventory.Device` validation to accept new `os.passive_fingerprint`, `metadata.passive_fingerprint` map keys.
- [ ] 8.8 Ship initial `visibility_enrichment_rules.yaml` pack mapping common p0f / JA4 signatures to `type_id`, `vendor_name`, `os.family`.

### 9. [Phase 1] Discovery ingestion integration

- [ ] 9.1 Register `passive-netprobe` in the `DiscoverySource` enum used by `network-discovery`.
- [ ] 9.2 Update the discovery ingest writer to persist fingerprint payloads onto the canonical `Device` resolved through `IP Alias Resolution`.
- [ ] 9.3 Hook `Rule-Driven Vendor and Type Enrichment` to consume passive-netprobe payloads.
- [ ] 9.4 Integration test: ingest synthetic events for an Armis-imported device IP and confirm enrichment.

### 10. [Phase 1] Identity reconciliation

- [ ] 10.1 Treat the passive fingerprint as a *weak* identifier signal in `Multi-Identifier Convergence` (never a sole basis for merge).
- [ ] 10.2 Property tests ensuring passive fingerprints cannot spuriously merge distinct strong-identifier devices.

### 11. [Phase 1] RBAC and capability surfacing

- [ ] 11.1 Add `visibility_profiles:read|write|delete` permissions to `elixir/serviceradar_core/lib/serviceradar/identity/rbac/catalog.ex`. `agent_capture:remote` is **not** added in Phase 1.
- [ ] 11.2 Register `host-network-visibility` as an agent capability in `agent-registry`; Phase 1 advertises `fingerprint` as `enabled`, every other surface as `unavailable`.
- [ ] 11.3 Surface `netprobe` sidecar status in the agent's `StatusResponse` capability bundle.

### 12. [Phase 1] Web UI (`elixir/web-ng/`) — minimal

- [ ] 12.1 Add `Settings → Discovery → Visibility Profiles` route, list view, and form (`lib/serviceradar_web_ng_web/live/settings/visibility_profiles_live/`).
- [ ] 12.2 Reuse the existing SRQL query builder for `target_query`.
- [ ] 12.3 Implement the fingerprint section of the toggle UI (per-protocol TCP / TLS / HTTP). Hide DPI, flow attribution, and process snapshot toggles behind a "Coming in a later phase" notice (or omit them entirely until Phase 2/3).
- [ ] 12.4 Implement target-count display (handles invalid SRQL → "Unknown" same as SNMP profiles).
- [ ] 12.5 Add "Network Visibility" panel to Device Detail that renders only the passive-fingerprint section in Phase 1.
- [ ] 12.6 Extend Agent Detail page with `netprobe` sidecar state and `host-network-visibility` capability badge.
- [ ] 12.7 Playwright tests for Phase-1 profile CRUD and device detail fingerprint panel.

### 13. [Phase 1] Packaging

- [ ] 13.1 Add `//rust/netprobe:netprobe` to `build/packaging/agent/BUILD.bazel` `pkg_files` (rename to `serviceradar-netprobe`, mode `0755`).
- [ ] 13.2 Update `build/packaging/packages.bzl` `PACKAGES["agent"]` to include the sidecar at `/usr/local/lib/serviceradar/bin/`.
- [ ] 13.3 deb/rpm postinst applies `setcap cap_net_raw+ep` to the sidecar binary (Phase 1 capability set; eBPF caps land with Phase 3).
- [ ] 13.4 Add `//rust/netprobe:netprobe` to `docker/images/BUILD.bazel` `agent_image_amd64` (and arm64 variant) file map.
- [ ] 13.5 Add a `netprobe.enabled` toggle under `helm/serviceradar/values.yaml` (default false).
- [ ] 13.6 Verify the resulting agent OCI image starts the sidecar on a Kind cluster and emits fingerprint events for a deliberately-crafted test packet.

### 14. [Phase 1] Documentation

- [ ] 14.1 Operator runbook `docs/agent/netprobe.md`: enabling profiles, capture-interface allowlist, troubleshooting (exit codes, restart back-off, dropped-events counter). Phase 1 scope only.
- [ ] 14.2 Privacy note documenting what is and is not captured.

### 15. [Phase 1] Validation

- [ ] 15.1 `bazel test //rust/netprobe/...` passes (Phase 1 test set).
- [ ] 15.2 `bazel test //go/pkg/agent/sidecar/... //go/pkg/agent/netprobe/...` passes.
- [ ] 15.3 `mix test --only visibility` passes in `elixir/serviceradar_core/`.
- [ ] 15.4 `mix test --only visibility_profiles_live` passes in `elixir/web-ng/`.
- [ ] 15.5 E2E suite: enable a profile scoped to `in:devices type:0`, send pcap fixtures through a test agent, assert an Armis-imported device gains `os.passive_fingerprint`.
- [ ] 15.6 `openspec validate add-host-network-visibility-sidecar --strict` passes.

---

## Phase 2 — Deep packet inspection (deferred)

### 16. [Phase 2] DPI dissectors in `netprobe`

- [ ] 16.1 Add `pktparse-rs` (or equivalent) to `Cargo.toml`; refresh crate-universe.
- [ ] 16.2 Implement the dissector pipeline assembler (parser feeds dissectors that subscribe to L7 prefixes).
- [ ] 16.3 Implement dissectors for HTTP/1.x, HTTP/2 cleartext, TLS SNI, DNS, SSH, FTP, QUIC version negotiation, MQTT, BitTorrent.
- [ ] 16.4 Apply privacy redaction at each dissector boundary (no URIs, no DNS names by default, no payload).
- [ ] 16.5 Activate the `DpiEvents` stream channel (placeholder reserved in Phase 1).
- [ ] 16.6 Emit `DpiEvent` records carrying `{5-tuple, protocol, confidence, observed_at}` only.
- [ ] 16.7 Per-protocol toggles honour `VisibilityProfile.dpi.protocols`.
- [ ] 16.8 Unit tests per dissector with PCAP fixtures.

### 17. [Phase 2] DPI ingestion + storage + UI

- [ ] 17.1 Bridge `DpiEvent` → device `metadata.dpi` updates.
- [ ] 17.2 Extend the discovery ingest writer accordingly.
- [ ] 17.3 Extend the Visibility Profile UI with the DPI section (replace the Phase 1 placeholder).
- [ ] 17.4 Extend the Network Visibility panel on Device Detail to render the DPI section.

---

## Phase 3 — eBPF flow attribution + process snapshots (deferred)

### 18. [Phase 3] eBPF programs

- [ ] 18.1 Add `aya`, `aya-ebpf`, `aya-log`, `procfs` to `Cargo.toml`.
- [ ] 18.2 Author eBPF programs under `rust/netprobe/ebpf/` (kprobes on `tcp_connect`, `inet_csk_accept`, `tcp_close`, UDP sendmsg/recvmsg, `inet_sock_set_state`).
- [ ] 18.3 Pin BPF maps under `/sys/fs/bpf/serviceradar/netprobe/` with `0700` perms so restart reattaches.
- [ ] 18.4 Implement userspace map readers correlating 5-tuples to PIDs via `procfs`.
- [ ] 18.5 Resolve PID → `comm`, redacted command line, UID, container-id.
- [ ] 18.6 Maintain a bounded LRU of active flows.
- [ ] 18.7 Activate the `FlowAttributionEvents` and `ProcessSnapshots` stream channels.
- [ ] 18.8 Implement degraded mode for kernels < 5.8.

### 19. [Phase 3] Capability + UI extensions

- [ ] 19.1 Extend deb/rpm postinst to add `cap_bpf,cap_perfmon` to the sidecar's file capabilities.
- [ ] 19.2 Extend `helm/serviceradar/templates/agent.yaml` `securityContext.capabilities.add` with `BPF` and `PERFMON`.
- [ ] 19.3 Extend the Visibility Profile UI with the flow-attribution and process-snapshot sections.
- [ ] 19.4 Add the "Process Listeners" tab to Device Detail for agent-host devices.
- [ ] 19.5 Surface kernel BPF support and degraded-mode status on the Agent Detail page.

---

## Phase 4 — NetFlow ↔ application attribution (deferred)

### 20. [Phase 4] `flow-collector` per-host slice

- [ ] 20.1 Extend `rust/flow-collector/` to publish a per-host slice (`flow.host-slice.<agent-id>`) for every agent advertising `host-network-visibility`.
- [ ] 20.2 Gate slice publication on a control-plane-managed allowlist so we never blanket-publish slices to unsubscribed agents.
- [ ] 20.3 Add `attributed_flow` event type to the flow pipeline contract.
- [ ] 20.4 Add per-slice observability metrics.

### 21. [Phase 4] Sidecar + bridge + UI

- [ ] 21.1 Implement `IngestExternalFlows` client-streamed RPC consumer in `netprobe`.
- [ ] 21.2 Annotate matched 5-tuples with PID / process / cmdline / uid / container-id; drop unmatched.
- [ ] 21.3 Add the Go bridge subscriber for `flow.host-slice.<agent-id>` and republish `attributed_flow` records.
- [ ] 21.4 Add the "Attributed Flows" view to the Flows dashboard.

---

## Phase 5 — Remote pcapng capture sessions (deferred)

### 22. [Phase 5] `netprobe` capture session RPC

- [ ] 22.1 Activate the `StartRemoteCapture` request message and `CaptureSessions(StartRemoteCapture) returns (stream PcapngBlock)` server-streamed RPC reserved in Phase 1.
- [ ] 22.2 Validate request against the agent-supplied `capture_interfaces` allowlist; reject otherwise.
- [ ] 22.3 Compile the libpcap-style BPF filter via the `pcap` crate; reject unparseable filters with a structured error.
- [ ] 22.4 Open a dedicated pcap handle for the session; emit a Section Header Block followed by Interface Description Block(s), then a stream of Enhanced Packet Blocks per pcapng.
- [ ] 22.5 Enforce hard caps on `duration_s` and `byte_cap`; emit a final `PcapngBlock` with `final = true` on graceful termination or cap hit.
- [ ] 22.6 Concurrent-session cap: 1 per `netprobe` instance in Phase 5; reject overlapping requests.
- [ ] 22.7 On agent UDS disconnect mid-session, terminate the session and free the pcap handle within 5 s.
- [ ] 22.8 Unit tests covering allowlist denial, filter compile failure, duration cap, byte cap, mid-session UDS close.

### 23. [Phase 5] Agent ↔ agent-gateway gRPC server-streaming RPC

- [ ] 23.1 Add a `RemotePacketCapture` gRPC service to the existing agent ↔ agent-gateway proto (the one that already carries the control stream and command bus), defining a single server-streaming RPC `Stream(StartRemoteCaptureSession) returns (stream RemotePacketCaptureFrame)` where `RemotePacketCaptureFrame` is a oneof of `PcapngBlock` and `SessionStateChanged`.
- [ ] 23.2 Verify the new RPC multiplexes onto the existing mTLS HTTP/2 connection (single `grpc.ClientConn` per agent ↔ gateway pair) and does not open a second TCP/TLS session.
- [ ] 23.3 Implement `go/pkg/agent/netprobe/capture.go`: agent-side handler that receives the gRPC stream, opens the netprobe `CaptureSessions` UDS RPC, and forwards `PcapngBlock` frames between netprobe and the gateway.
- [ ] 23.4 Implement byte-counting per-session in the agent and emit a `SessionStateChanged` frame at 1 Hz so the gateway / `core-elx` can track `bytes_streamed` without parsing pcapng.
- [ ] 23.5 Handle gateway-initiated stream cancellation (gRPC client-cancel); propagate to netprobe within 1 s.
- [ ] 23.6 Surface "active capture session" indicator in the agent's status response so operators can see busy agents.

### 24. [Phase 5] `core-elx` session lifecycle, RBAC, audit

- [ ] 24.1 Create `Serviceradar.Telemetry.RemotePacketCaptureSession` Ash resource (per D13b attribute list).
- [ ] 24.2 Generate migration via `mix ash.codegen add_remote_packet_capture_session`; apply with `mix ash.migrate`.
- [ ] 24.3 Add Ash actions: `request_capture` (validates user + RBAC + per-tenant caps), `transition_state`, `complete`, `abort`.
- [ ] 24.4 Add `agent_capture:remote` and `agent_capture:audit_view` permissions to `Serviceradar.Identity.RBAC.Catalog`.
- [ ] 24.5 Add policies on the resource enforcing the new permissions per partition.
- [ ] 24.6 Wire every state transition to the audit log capability so all session events appear in the standard audit feed.
- [ ] 24.7 Implement a `web-ng` streaming endpoint (Phoenix Channel) that authenticates the client (`add-cli-device-auth`), dispatches the request to `core-elx` over ERTS RPC for RBAC + audit + session-record creation, then proxies pcapng bytes between the client and `core-elx`.
- [ ] 24.8 Implement the `core-elx` side that brokers between `web-ng` and the `agent-gateway` command bus over ERTS RPC, counts bytes for the session record, and surfaces session state.
- [ ] 24.9 Implement client-disconnect detection at the `web-ng` edge: on stream close from the client side, propagate via ERTS RPC to `core-elx`, which sends `StopRemoteCaptureSession` to the agent and transitions state to `aborted`.
- [ ] 24.10 Implement tenant-level cap ceilings: configurable max `duration_s`, `byte_cap`, and concurrent sessions per partition.

### 25. [Phase 5] `srctl` Go CLI: rename + device-code auth + capture subcommand

#### 25a. Rename and packaging

- [ ] 25.1 Rename the Go CLI Bazel target so the packaged binary is `srctl` (Go source remains at `go/cmd/cli/`). Update `go/cmd/cli/BUILD.bazel`.
- [ ] 25.2 Update deb/rpm/tarball/OCI packaging to install `srctl` and to create a `serviceradar-cli` symlink that points to `srctl` for backward compatibility.
- [ ] 25.3 Update existing ServiceRadar docs (`docs/docs/edge-agent-onboarding.md`, `docs/docs/agent-configuration.md`, `docs/docs/web-ui-overview.md`, `docs/docs/agent-release-management.md`, `docs/CNCF/*`) to use `srctl` as the canonical command, with a one-time call-out that `serviceradar-cli` remains as a deprecated alias.
- [ ] 25.4 Add a release-notes entry announcing the rename, the symlink compat window (one release cycle), and the deprecation.

#### 25b. Device-code auth client (ported from JS CLI)

- [ ] 25.5 Add an `auth` subcommand group to `srctl` with `login`, `status`, `logout`.
- [ ] 25.6 Implement the RFC 8628 device-code client in Go, hitting the `POST /api/v1/cli/auth/device` and `POST /api/v1/cli/auth/token` endpoints landed by `add-cli-device-auth`.
- [ ] 25.7 Persist the issued Guardian JWT in OS-appropriate user credential storage (`$XDG_CONFIG_HOME/serviceradar/credentials.json` on Linux, `~/Library/Application Support/serviceradar/credentials.json` on macOS, `%APPDATA%\serviceradar\credentials.json` on Windows), file permissions `0600`.
- [ ] 25.8 Implement `srctl auth status` (prints active instance, expiry, scopes) and `srctl auth logout` (deletes local credentials; no server-side revoke in this task — Settings UI handles revocation).
- [ ] 25.9 Cross-platform manual smoke test (Linux + macOS + Windows) of `auth login` against a dev instance.

#### 25c. `srctl capture` subcommand

- [ ] 25.10 Add the `capture` subcommand accepting `--agent`, `--interface`, `--filter`, `--duration`, `--snaplen`, `--byte-cap`.
- [ ] 25.11 Read cached device-code JWT from the credentials store; refuse to start a session if missing or expired, printing a stderr hint to run `srctl auth login` first.
- [ ] 25.12 Open the streaming HTTPS endpoint on `web-ng`, send the JWT as `Authorization: Bearer …`.
- [ ] 25.13 Stream pcapng to stdout unmodified using direct byte writes (`os.Stdout.Write`); do not interpose any encoder, buffer, or Writer that performs translation.
- [ ] 25.14 Print session metadata to stderr only: session id, expected termination time, audit-record URL. Stdout MUST carry only pcapng bytes.
- [ ] 25.15 Exit 0 on graceful completion, distinct non-zero codes for auth failure (10), RBAC denial (11), BPF filter parse failure (12), agent unreachable (13), session cap exhausted (14), upstream cancellation (15).
- [ ] 25.16 Document `srctl capture | wireshark -k -i -` and `srctl capture | tshark -i -` usage in the runbook.

### 26. [Phase 5] Web UI — remote capture

- [ ] 26.1 Add a "Start Remote Capture" action button on Agent Detail (and Device Detail when the device is an agent host), guarded by `agent_capture:remote`.
- [ ] 26.2 Implement a modal that collects `interface`, `filter`, `duration_s`, `snaplen`, `byte_cap`; pre-fills allowlisted interfaces; rejects values exceeding tenant caps inline.
- [ ] 26.3 Render an active-session card while the session runs: session id, elapsed time, bytes streamed, BPF filter (rendered with audit treatment per the design's open question), "Stop" button.
- [ ] 26.4 Add a "Capture history" view rendering completed and aborted sessions (`agent_capture:audit_view`).
- [ ] 26.5 Render the active session indicator on the Agent Detail capability badge so operators see at a glance that an agent is in a capture session.
- [ ] 26.6 Playwright tests for the request modal, the active-session card, the history view, and the RBAC denial path.

### 27. [Phase 5] `agent-connectivity` and `agent-registry` integration

- [ ] 27.1 Extend the agent control-stream protocol with a `RemotePacketCaptureSession` envelope that supports bidirectional state transitions and high-bandwidth pcapng forwarding from agent to gateway.
- [ ] 27.2 Add `remote-packet-capture` to the agent capability vocabulary in `agent-registry`; advertise as `enabled` for agents on partitions where the feature is enabled, `unavailable` otherwise.
- [ ] 27.3 Surface the active-session state on the agent registry record so dashboards can find busy agents without polling agent status directly.

### 28. [Phase 5] Validation

- [ ] 28.1 E2E test: a user with `agent_capture:remote` runs `srctl capture --agent <id> --interface eth0 --filter "icmp" --duration 5`, observes pcapng on stdout, validates with `tshark -r -` that ICMP packets are present.
- [ ] 28.2 E2E test: a user without `agent_capture:remote` is denied with a non-zero exit code and an audit record is written.
- [ ] 28.3 Cap-enforcement tests: duration overrun, byte overrun, concurrent-session collision.
- [ ] 28.4 Mid-stream client-disconnect test: `srctl` is killed; verify the agent-side session is terminated within 5 s and the resource state transitions to `aborted`.

---

## Phase 6 — Polish and hardening (deferred)

### 29. [Phase 6] Operator surfaces

- [ ] 29.1 Add Capture-Interface Allowlist editor to Agent Detail.
- [ ] 29.2 Add per-profile "opt-in" toggles for DNS query names and full HTTP URIs (off by default).
- [ ] 29.3 Update the operator runbook with full-feature troubleshooting (DPI, eBPF, remote capture).
- [ ] 29.4 Publish the Cisco Secure Workload labelling cookbook.
- [ ] 29.5 Ship a Grafana dashboard JSON under `dashboards/` covering sidecar metrics, slice metrics, and capture-session metrics.
- [ ] 29.6 Add a CI matrix entry that runs the kernel-degraded-mode test on a kernel-< 5.8 runner.

### 30. [Phase 6] Future-proofing

- [ ] 30.1 Investigate a native Wireshark `extcap` shim that lists ServiceRadar agents directly in Wireshark's capture-source picker (separate proposal).
- [ ] 30.2 Investigate optional `core-elx`-side capture staging into object storage with `srctl capture history download` (separate proposal).
