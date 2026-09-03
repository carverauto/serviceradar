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
- [x] 1.4 Add `huginn-net`, `tokio`, `prost`, `pcap`, `nix` to `rust/netprobe/Cargo.toml` (Phase-1 dependency set only; eBPF / DPI crates land with their phases). Regenerate crate-universe via `bazel mod tidy`.
- [x] 1.5 Verify `bazel build //rust/netprobe:netprobe` succeeds with the default platform.
- [x] 1.6 Verify `bazel build --platforms=//build/platforms:linux_x86_64_musl //rust/netprobe:netprobe` produces a static binary (`file` reports "statically linked", `ldd` says "not a dynamic executable").
- [x] 1.7 Add a CI matrix entry in `../../../.forgejo/workflows/rust-tests.yml` for the musl static build (x86_64 + aarch64).
- [x] 1.8 Define Bazel platforms `//build/platforms:linux_x86_64_musl` and `:linux_aarch64_musl` if not already present.

### 2. [Phase 1] `netprobe` Rust crate — skeleton + lifecycle

- [x] 2.1 Scaffold `rust/netprobe/Cargo.toml` (`name = "serviceradar-netprobe"`, `edition = "2021"`, Apache-2.0) and `rust/netprobe/BUILD.bazel` mirroring `rust/trapd/BUILD.bazel`.
- [x] 2.2 Implement `main.rs` with a `tokio` runtime, CLI flags `--socket`, `--config`, `--log-format`, `--health-port` (Phase 1 omits `--bpf-pin-dir`).
- [x] 2.3 Implement Unix-domain-socket server accepting a single agent client; reject concurrent clients.
- [x] 2.4 Implement length-prefixed protobuf framing per `proto/agent/netprobe/v1/netprobe.proto`.
- [x] 2.5 Implement `Ping`/`PingAck` and graceful shutdown on `SIGTERM` (flush events, close UDS, exit within 5 s).
- [x] 2.6 Implement capability sequencing for Phase 1: assert `CAP_NET_RAW` at start (already available from systemd / pod securityContext); open pcap handles; drop to a non-root UID before serving UDS. `CAP_BPF` / `CAP_PERFMON` assertions land with Phase 3.
- [x] 2.7 Implement the capture-interface allowlist enforcement (refuse `any`, refuse wildcards, refuse not-in-list interfaces).
- [x] 2.8 Expose Prometheus metrics on a localhost-only HTTP endpoint: `_packets_processed_total`, `_packets_dropped_total`, `_events_emitted_total{stream="fingerprint"}`, `_signature_failures_total`, `_uptime_seconds`.
- [x] 2.9 Unit tests for framing, UDS lifecycle, capability sequencing, allowlist enforcement.

### 3. [Phase 1] `netprobe` — passive fingerprinting

- [x] 3.1 Integrate `huginn-net` for TCP p0f-style analysis on the configured capture interfaces.
- [x] 3.2 Integrate TLS JA4 / JA4S extraction.
- [x] 3.3 Integrate HTTP header signature extraction limited to non-payload headers (`Server`, `User-Agent`, `Accept-Language`).
- [x] 3.4 Implement per-(IP, protocol) sample-interval rate limiting honouring `sample_interval_ms`.
- [x] 3.5 Emit `FingerprintEvent` records on the dedicated server-streamed channel.
- [x] 3.6 Unit tests with pcap fixtures producing each event variant.
- [x] 3.7 Integration test (`#[tokio::test]`) running the sidecar end-to-end against fixture traffic.

### 4. [Phase 1] IPC protocol skeleton (`proto/agent/netprobe/v1/`)

- [x] 4.1 Create `proto/agent/netprobe/v1/netprobe.proto` with messages `VisibilityAgentConfig`, `DeviceBinding`, `FingerprintEvent` (oneof TCP/TLS/HTTP), `Ping`, `PingAck`. Reserve field numbers and message names for `DpiEvent`, `FlowAttributionEvent`, `ProcessSnapshot`, `ExternalFlowRecord`, `StartRemoteCapture`, `PcapngBlock` — defined as empty placeholder messages with TODO comments so later phases extend without breaking changes.
- [x] 4.2 Add `buf` lint pass; no breaking-change checks yet (v1 alpha until first archive).
- [x] 4.3 Generate Go bindings under `proto/agent/netprobe/v1/` and Rust bindings via the `rust/netprobe/build.rs` Prost `OUT_DIR` include path.
- [x] 4.4 Document framing rules: 4-byte big-endian length prefix, max frame size 4 MiB.

### 5. [Phase 1] Agent sidecar runtime (`go/pkg/agent/sidecar/`)

- [x] 5.1 Create `manager.go` defining `Manager` that owns `[]Sidecar`, exposes `Start(ctx)` / `Stop(ctx)`.
- [x] 5.2 Define `Sidecar` interface: `Name()`, `BinaryPath()`, `Args(socketPath, configPath string) []string`, `OnHealthy(client)`, `OnUnhealthy(err)`.
- [x] 5.3 Implement process supervision via `exec.CommandContext`, structured logger passthrough tagged `sidecar=<name>` + `pid=<pid>`.
- [x] 5.4 Implement exponential restart back-off (1s → 60s cap); per-minute restart-cap circuit breaker.
- [x] 5.5 Implement health probe loop (5 s default); mark unhealthy after 3 consecutive failures.
- [x] 5.6 Surface sidecar state into `StatusResponse` (`name`, `state`, `pid`, `last_health_at`, `restart_count`, `last_error`).
- [x] 5.7 Implement graceful shutdown: SIGTERM → 5 s grace → SIGKILL.
- [x] 5.8 Unit-test the manager with a fake `Sidecar` and a fake child script.
- [x] 5.9 README at `go/pkg/agent/sidecar/README.md` documenting the contract for future sidecars.

### 6. [Phase 1] `netprobe` Go bridge (`go/pkg/agent/netprobe/`)

- [x] 6.1 Implement a `Sidecar` for `netprobe` plugged into the runtime from §5.
- [x] 6.2 Implement the IPC client: opens UDS, sends `ApplyConfig`, drains the `FingerprintEvents` stream.
- [x] 6.3 Translate `FingerprintEvent` records into discovery ingestion records bound to canonical devices via `IP Alias Resolution`.
- [x] 6.4 Backpressure: drop new events when downstream is slow; increment `_events_dropped_total{stream="fingerprint",reason="backpressure"}`.
- [x] 6.5 Unit tests for the fingerprint translation path.

### 7. [Phase 1] Agent config delivery

- [x] 7.1 Extend `proto/monitoring.proto` `AgentConfigResponse` with `VisibilityConfig visibility_config` (parallel to `sysmon_config` / `snmp_config`).
- [x] 7.2 Define `VisibilityConfig`: `enabled`, `capture_interfaces`, `binary_overrides {path}`, repeated `device_bindings {ip, profile_id, profile_name, fingerprint, sample_interval_ms}`. Reserve fields for `dpi`, `flow_attribution`, `process_snapshot_interval_s` so later phases extend without breaking changes.
- [x] 7.3 Plumb the new field through Elixir compiler output and Go parser.
- [x] 7.4 Verify chunked delivery (`add-streamed-agent-config`) handles the new field; add a streaming test case with 5k device bindings.
- [x] 7.5 Hash the new sub-config into the agent's config version hash.

### 8. [Phase 1] Ash control plane (`elixir/serviceradar_core/`)

- [x] 8.1 Create `lib/serviceradar/inventory/visibility_profile.ex` Ash resource. Phase 1 attribute set: `name`, `description`, `enabled`, `target_query`, `priority`, `fingerprint {tcp, tls, http}`, `sample_interval_ms`, `retention_days`, `partition_id`, temporal fields. Add the remaining maps (`dpi`, `flow_attribution`, `process_snapshot_interval_s`) as nullable so they can be populated by later phases without another migration.
- [x] 8.2 Add the visibility profile migration and verify it applies with `mix ash.migrate`. `mix ash.codegen add_visibility_profile --dry-run` still emits broad unrelated historical snapshot drift in this repo, so the committed migration is the scoped hand-written migration at `20260527123000_create_visibility_profiles.exs`.
- [x] 8.3 Add `Ash.Policy.Authorizer` policies mirroring `SysmonProfile`.
- [x] 8.4 Create `lib/serviceradar/agent_config/compilers/visibility_compiler.ex` using `SrqlTargetResolver.resolve_for_device/2`. Compile only the fingerprint surface in Phase 1.
- [x] 8.5 Unit tests for compiler: priority ordering, default scope `in:devices`, disabled profile handling.
- [x] 8.6 Wire compiler output into `AgentConfigResponse.visibility_config`.
- [x] 8.7 Extend `Serviceradar.Inventory.Device` validation to accept new `os.passive_fingerprint`, `metadata.passive_fingerprint` map keys.
- [x] 8.8 Ship initial `visibility_enrichment_rules.yaml` pack mapping common p0f / JA4 signatures to `type_id`, `vendor_name`, `os.family`.
- [x] 8.9 Enable AshPaperTrail on Ash resources that control packet-observation posture (`VisibilityProfile` and any capture-interface allowlist resource) so profile/allowlist creates, updates, disables, and deletes are auditable with actor, partition, request id, prior value, and new value.

### 9. [Phase 1] Discovery ingestion integration

- [x] 9.1 Register `passive-netprobe` in the `DiscoverySource` enum used by `network-discovery`.
- [x] 9.2 Update the discovery ingest writer to persist fingerprint payloads onto the canonical `Device` resolved through `IP Alias Resolution`.
- [x] 9.3 Hook `Rule-Driven Vendor and Type Enrichment` to consume passive-netprobe payloads.
- [x] 9.4 Integration test: ingest synthetic events for an Armis-imported device IP and confirm enrichment.

### 10. [Phase 1] Identity reconciliation

- [x] 10.1 Treat the passive fingerprint as a *weak* identifier signal in `Multi-Identifier Convergence` (never a sole basis for merge).
- [x] 10.2 Property tests ensuring passive fingerprints cannot spuriously merge distinct strong-identifier devices.

### 11. [Phase 1] RBAC and capability surfacing

- [x] 11.1 Add `visibility_profiles:read|write|delete` permissions to `elixir/serviceradar_core/lib/serviceradar/identity/rbac/catalog.ex`. `agent_capture:remote` is **not** added in Phase 1.
- [x] 11.2 Register `host-network-visibility` as an agent capability in `agent-registry`; Phase 1 advertises `fingerprint` as `enabled`, every other surface as `unavailable`.
- [x] 11.3 Surface `netprobe` sidecar status in the agent's `StatusResponse` capability bundle.

### 12. [Phase 1] Web UI (`elixir/web-ng/`) — minimal

- [x] 12.1 Add `Settings → Discovery → Visibility Profiles` route, list view, and form (`lib/serviceradar_web_ng_web/live/settings/visibility_profiles_live/`).
- [x] 12.2 Reuse the existing SRQL query builder for `target_query`.
- [x] 12.3 Implement the fingerprint section of the toggle UI (per-protocol TCP / TLS / HTTP). Hide DPI, flow attribution, and process snapshot toggles behind a "Coming in a later phase" notice (or omit them entirely until Phase 2/3).
- [x] 12.4 Implement target-count display (handles invalid SRQL → "Unknown" same as SNMP profiles).
- [x] 12.5 Add "Network Visibility" panel to Device Detail that renders only the passive-fingerprint section in Phase 1.
- [x] 12.6 Extend Agent Detail page with `netprobe` sidecar state and `host-network-visibility` capability badge.
- [x] 12.7 Playwright tests for Phase-1 profile CRUD and device detail fingerprint panel.

### 13. [Phase 1] Packaging

- [x] 13.1 Add `//rust/netprobe:netprobe` to `build/packaging/agent/BUILD.bazel` `pkg_files` (rename to `serviceradar-netprobe`, mode `0755`).
- [x] 13.2 Update `build/packaging/packages.bzl` `PACKAGES["agent"]` to include the sidecar at `/usr/local/lib/serviceradar/bin/` and declare the Phase 1 libpcap runtime dependency for deb/rpm packages.
- [x] 13.3 deb/rpm postinst applies `setcap cap_net_raw+ep` to the sidecar binary (Phase 1 capability set; eBPF caps land with Phase 3).
- [x] 13.4 Add `//rust/netprobe:netprobe` to `docker/images/BUILD.bazel` `agent_image_amd64` file map and include libpcap/glibc runtime libraries in the Alpine netutils rootfs. No arm64 agent image target currently exists in `docker/images/BUILD.bazel`.
- [x] 13.5 Add a `netprobe.enabled` toggle under `helm/serviceradar/values.yaml` (default false).
- [ ] 13.6 Verify the resulting agent OCI image starts the sidecar on a Kind cluster and emits fingerprint events for a deliberately-crafted test packet.

### 14. [Phase 1] Documentation

- [x] 14.1 Operator runbook `docs/docs/netprobe.md`: enabling profiles, capture-interface allowlist, troubleshooting (exit codes, restart back-off, dropped-events counter). Phase 1 scope only.
- [x] 14.2 Privacy note documenting what is and is not captured.

### 15. [Phase 1] Validation

- [x] 15.1 `bazel test //rust/netprobe/...` passes (Phase 1 test set).
- [x] 15.2 `bazel test //go/pkg/agent/sidecar/... //go/pkg/agent/netprobe/...` passes.
- [x] 15.3 `mix test --only visibility` passes in `elixir/serviceradar_core/`.
- [x] 15.4 `mix test --only visibility_profiles_live` passes in `elixir/web-ng/`.
- [ ] 15.5 E2E suite: enable a profile scoped to `in:devices type:0`, send pcap fixtures through a test agent, assert an Armis-imported device gains `os.passive_fingerprint`.
- [x] 15.6 `openspec validate add-host-network-visibility-sidecar --strict` passes.

---

## Phase 2 — Deep packet inspection (deferred)

### 16. [Phase 2] DPI dissectors in `netprobe`

- [x] 16.1 Add `pktparse-rs` (or equivalent) to `Cargo.toml`; refresh crate-universe.
- [x] 16.2 Implement the dissector pipeline assembler (parser feeds dissectors that subscribe to L7 prefixes).
- [x] 16.3 Implement dissectors for HTTP/1.x, HTTP/2 cleartext, TLS SNI, DNS, SSH, FTP, QUIC version negotiation, MQTT, BitTorrent.
- [x] 16.4 Apply privacy redaction at each dissector boundary (no URIs, no DNS names by default, no payload).
- [x] 16.5 Activate the `DpiEvents` stream channel (placeholder reserved in Phase 1).
- [x] 16.6 Emit `DpiEvent` records carrying `{5-tuple, protocol, confidence, observed_at}` only.
- [x] 16.7 Per-protocol toggles honour `VisibilityProfile.dpi.protocols`.
- [x] 16.8 Unit tests per dissector with PCAP fixtures.

### 17. [Phase 2] DPI ingestion + storage + UI

- [x] 17.1 Bridge `DpiEvent` → device `metadata.dpi` updates.
- [x] 17.2 Extend the discovery ingest writer accordingly.
- [x] 17.3 Extend the Visibility Profile UI with the DPI section (replace the Phase 1 placeholder).
- [x] 17.4 Extend the Network Visibility panel on Device Detail to render the DPI section.

---

## Phase 3 — Kernel-side eBPF rewrite (capture + attribution + libpcap deletion)

Phase 3 replaces the libpcap-userspace continuous capture path with kernel-side eBPF. After Phase 3 cutover, the only continuous-path libpcap dependency is in the Phase-5-only `remote-capture` Cargo feature.

### 18. [Phase 3] eBPF capture path + activation

- [x] 18.1 Add `aya`, `aya-ebpf`, `aya-log`, AF_XDP bindings (e.g. `xsk-rs` or `aya::maps::xdp::XskMap`), `procfs` to `rust/netprobe/Cargo.toml`. Regenerate crate-universe via `bazel mod tidy`.
- [x] 18.2 Create `rust/netprobe/ebpf/` as a separate Cargo crate compiled to BPF bytecode via `aya-ebpf`. Add a Bazel `cargo_build_script` (or `aya-build`-driven rule) that embeds the compiled `.o` blobs into the userspace binary.
- [x] 18.3 Vendor `vmlinux.h` from the earliest supported kernel (5.8) for BTF-CO-RE. Document the regeneration procedure in `BUILD.md`.
- [x] 18.4 Author `cls_bpf` TC ingress + egress programs: parse 5-tuple from the packet, look up `flow_table` map, bump counters on hit/classified, redirect first N packets to AF_XDP on hit/classifying, insert + redirect on miss.
- [x] 18.5 Author `kprobe/tcp_rcv_state_process` (or kernel-version equivalent) that extracts SYN TCP options (`ttl`, `window_size`, `mss`, `options_layout`, `quirks`, `ip_version`, `window_scale`, `payload_class`) at connection setup and emits one perf-RB event per new connection.
- [x] 18.6 Author socket-lifecycle kprobes: `tcp_connect`, `inet_csk_accept`, `tcp_close`, `udp_sendmsg`, `udp_recvmsg`, plus `tracepoint/sock/inet_sock_set_state` backfill. Populate `flow_to_pid` and `process_info` BPF maps.
- [x] 18.7 Define BPF maps with explicit capacity bounds: `flow_table` (default 65,536 entries per interface, LRU), `flow_to_pid`, `process_info`, `interface_allowlist`. All pinned under `/sys/fs/bpf/serviceradar/netprobe/` with `0700` perms.
- [x] 18.8 Implement AF_XDP ring binding per allowlisted interface. Default per-flow packet redirect budget = 16. **Userspace consumer is a dedicated OS thread per interface (`std::thread::spawn`), pinned via `sched_setaffinity` to a core local to the interface's IRQ affinity** — NOT a tokio task. Thread runs a busy-poll loop with adaptive backoff (default 10 µs → 1 ms when idle). The consumer communicates with the tokio main loop via a SPSC channel (`flume` or `crossbeam-channel`, implementer's choice). See `design.md` D4d for rationale; `design.md` D4e explains why this is a thread-per-core decision, not a full compio migration.
- [x] 18.9 Implement the userspace classifier that consumes the AF_XDP ring, runs the existing 9-dissector pack (relocated from `dpi.rs`'s pcap-driven loop), writes `classified_as` back to flow_table via BPF map syscall.
- [x] 18.10 (amended) Wire the §31.9 OS-match ensemble to consume the §31.4 `p0f_signatures` ring buffer. One ensemble evaluation per matched SYN; emit `FingerprintEvent` per `design.md` D14.
- [x] 18.11 Userspace map readers correlating 5-tuples to PIDs via the eBPF maps + `/proc` enrichment for `comm`, redacted `cmdline`, UID, container_id.
- [x] 18.12 Activate the `FlowAttributionEvents` IPC stream channel; emit one event per matched `(5-tuple, PID)` join from eBPF maps.
- [x] 18.13 Activate the `ProcessSnapshots` IPC stream channel; periodic listener-map enumeration via `/proc` joined against eBPF `process_info` map.
- [x] 18.14 Add kernel-version probe at startup; refuse to attach eBPF programs on kernel < 5.8 and advertise `host-network-visibility = unavailable`. Remove the legacy `degraded` enum value from the agent capability advertising.
- [x] 18.15 CPU benchmark harness: synthesize a target workload (e.g. 500 Mbps / 50k pps mixed HTTP+TLS+DNS); assert sustained userspace CPU < 3% of one core post-cutover. Compare against the libpcap-stopgap baseline and document the delta in the runbook.
- [x] 18.16 BPF program verifier CI: load every TC and kprobe program against a kernel-5.8 fixture; assert successful verification. Repeat for 5.15 and 6.x stable.
- [x] 18.17 Kernel-too-old CI: run netprobe on a 5.4 kernel image; assert it exits cleanly with `host-network-visibility = unavailable` advertised.
- [x] 18.18 Flow-cache hit-rate assertion: under the §18.15 workload, assert `flow_table` hit ratio > 95% (> 95% of packets short-circuit in-kernel and never reach userspace).
- [x] 18.19 Replace `tokio::sync::broadcast` for `FingerprintEvent` and `DpiEvent` IPC fan-out with per-consumer SPSC channels (`flume` or `crossbeam-channel`). The IPC server's single-client gate already guarantees one subscriber, so the SPMC fan-out shape is unnecessary overhead. Pool the `prost::Message::encode_to_vec` buffer per consumer thread so steady-state event encoding produces zero allocations after warmup; expose `serviceradar_netprobe_encode_buffer_reuses_total` so we can confirm steady-state allocation-free behavior in CI.

### 19. [Phase 3] libpcap deletion + packaging + UI surfaces

- [x] 19.1 Delete the libpcap capture worker in `rust/netprobe/src/capture.rs`; replace with the AF_XDP consumer from §18.9.
- [x] 19.2 Delete the per-packet fingerprint invocation from the capture worker (replaced by the §18.10 license-clean p0f signature ring consumer).
- [x] 19.3 Delete the per-packet DPI dispatch from the capture worker (replaced by §18.9).
- [x] 19.4 Implement adaptive sampling on the AF_XDP consumer (per the `Adaptive sampling under sustained CPU pressure` requirement): sliding-window CPU metric; under sustained pressure (default > 5% of one core for 30s), reduce the per-flow packet redirect budget toward 1. Expose `serviceradar_netprobe_sampling_budget` metric.
- [x] 19.5 Move `pcap = { optional = true }` behind a `remote-capture` Cargo feature. The default build no longer includes libpcap.
- [x] 19.6 Update deb/rpm packaging: default packages do not declare `libpcap0.8` / `libpcap` as runtime dependencies; if a future package variant enables `remote-capture`, list libpcap as `Recommends` rather than `Depends`.
- [x] 19.7 Verify `ldd /usr/local/lib/serviceradar/bin/serviceradar-netprobe` does not show `libpcap.so` in the default `release` build profile. Add a CI assertion.
- [x] 19.8 Extend deb/rpm postinst to add `cap_bpf,cap_perfmon` to the sidecar binary's file capabilities (in addition to existing `cap_net_raw`).
- [x] 19.9 Extend `helm/serviceradar/templates/agent.yaml` `securityContext.capabilities.add` with `BPF` and `PERFMON`.
- [x] 19.10 Extend the Visibility Profile UI with the flow-attribution and process-snapshot sections (replace Phase 1 placeholder copy).
- [x] 19.11 Add the "Process Listeners" tab to Device Detail for agent-host devices.
- [x] 19.12 Surface kernel BPF support state on the Agent Detail page (`available` / `unavailable` only; no `degraded`).
- [ ] 19.13 Full E2E: enable a profile scoped to `in:devices type:0` with `dpi.protocols = ["tls", "dns"]` on a real kernel-5.15 host; send pcap fixtures; assert (a) flow_table entries populate, (b) DPI events emit for first N packets per flow and stop after classification, (c) p0f signature-ring OS match fires once per connection, (d) Armis-imported device gains `os.passive_fingerprint`, (e) `metadata.dpi.tls.count` increments.

---

## Phase 4 — NetFlow to application attribution (deferred)

Every checked host-slice task in section 20 records the retired demo canary and
is historical evidence only, not an active production requirement. Task 21.3
supersedes that architecture with agent-up persisted observations and core-side
CNPG correlation; production must not re-enable the host-slice subscriber or a
`flow.attributed.*` subject.
Remaining TCP producer correctness, core admission, and acknowledgement work is
owned by `harden-flow-attribution-pipeline` for GitHub #4029, #4030, and #4031.

### 20. [RETIRED CANARY HISTORY] `flow-collector` per-host slice

- [x] 20.1 Extend `rust/flow-collector/` to publish a per-host slice (`flow.host-slice.<agent-id>`) for every agent advertising `host-network-visibility`.
- [x] 20.2 Gate slice publication on a control-plane-managed allowlist so we never blanket-publish slices to unsubscribed agents.
- [x] 20.3 Add `attributed_flow` event type to the flow pipeline contract.
- [x] 20.4 Add per-slice observability metrics.
- [x] 20.5 [B-5 sub-issue 1] Wire `GenerateAgentFlowCollectorCreds` into agent enrollment + bundle delivery: server-side mint via `ProvisionAgentWorker`, persist on `OnboardingPackage` (AshCloak), tar `creds/nats.creds` into the agent bundle, extract to `/etc/serviceradar/creds/nats.creds` mode 0600 in `agent_enroll.go`. Regression test: a creds file minted for agent A cannot publish to `flow.host-slice.<agent-B>`. (Commit 40dcd7bf8.)
- [x] 20.6 [B-5 sub-issue 2] Scope core publish ACL to `flow.attributed.<partition>` rather than a blanket allow. Implementation: `GeneratePartitionCoreCreds` mints per-partition core creds; `nats-server.conf` and `nats-cloud.conf` declare subject-scoped publish ACLs; two ACL regression tests assert (a) core can publish to its own partition's attributed subject and (b) core cannot publish to a foreign partition's attributed subject. (Commit f0f2900fa.)
- [x] 20.7 [B-5 follow-up #1] k8s/Helm partition templating: replace `allow: [">"]` with subject-scoped ACLs for `core` / `datasvc` / `agent` / `db-event-writer` / `zen` role CNs across `helm/serviceradar/values.yaml`, `helm/serviceradar/templates/nats.yaml`, `helm/serviceradar/templates/core.yaml`, and `k8s/demo/base/configmap.yaml`. Precedence: coalesce top-level `partitionId`, `agent.partitionId`, then fallback `"default"`. (Commit d043401e6.)
- [x] 20.8 [B-5 follow-up #2] Substitute `__SERVICERADAR_PARTITION_ID__` in rpm/deb postinstall via `sed -i`, sourced from `SERVICERADAR_OTX_PARTITION` env or `/etc/serviceradar/nats.env`. Idempotent (safe to re-run on upgrade). (Commit 202c0dfdf.)
- [x] 20.9 [B-5 follow-up #5] Agent NATS flow publisher consumes `nats_creds_file` from bundle config via `nats.UserCredentials(path)`; fails loud when configured but missing (no silent fallback to anonymous publish). (Commit 1fd5d82c9.)
- [x] 20.10 [Mi-85 follow-up] Reconcile Elixir attribution caps to bytes (16 / 64 / 256) with UTF-8 codepoint boundary trim matching the proto contract; telemetry metadata renamed `original_bytes` / `truncated_bytes` (was character-count based). (Commit fcf0428cc.)
- [x] 20.11 [B-5 follow-up #4] `datasvc.yaml` exports `SERVICERADAR_OTX_PARTITION` (mirrors the `core.yaml` env wiring) so datasvc resolves partition consistently with core.
- [x] 20.12 [B-5 docs cleanup] `k8s/demo` configmap header recipe corrected: replace stale `envsubst` instructions with the `sed` substitution pattern that matches the deployed templating flow.
- [x] 20.13 [Mi-87 docs cleanup] Strip stale `drop_policy` references from `docs/docs/troubleshooting-guide.md` and `docs/docs/netflow.md` (the field was removed but the docs still referenced it).
- [x] 20.14 [Mi-85 proto contract] Add byte-cap doc comments for `comm` (16 bytes) and `container_id` (64 bytes) in `proto/flow/flow.proto` so the cap contract lives next to the proto field definitions.
- [~] 20.15 **SUPERSEDED / NOT APPLICABLE.** `redacted_cmdline` remains capped in the agent-up payload, but the deployed task 21.3 path has no `flow.attributed.<partition>` publisher or subject-depth guard. Partition authority comes from the authenticated status context before `flow_process_attribution_current` persistence and in-place OCSF correlation.
- [x] 20.16 [B-5 #4] ExUnit coverage for `ProvisionAgentWorker.perform/1`. `ProvisionAgentWorker.perform/2` now has an `:account_client` injection seam mirroring `ControllerHealthWorker`'s `:awx_client`; `test/serviceradar/edge/workers/provision_agent_worker_test.exs` covers every discard branch, the happy path, `{:grpc_error, _}`, `:not_connected`, and catch-all `{:error, _}` end-to-end against a real `ServiceRadar.Repo` with `SystemActor.system(:test)` (no `authorize?: false`). The implementation also fixes the Ash-safe argument flow for credential create/attach and aligns the `OnboardingPackage` AshCloak physical column with `encrypted_nats_creds_ciphertext`.
- [~] 20.17 **SUPERSEDED / NOT APPLICABLE.** Production flow attribution no longer gives agents flow-collector NATS credentials or delivers per-agent host slices through `config.flow-collector.<agent_id>.>`, so this change has no flow-attribution credential to rotate.
- [x] 20.18 [Mi-85 #9] Add an Elixir proto regen Makefile target wrapping `protoc-gen-elixir` so the Elixir bindings cannot drift from `proto/flow/flow.proto` on subsequent proto changes. Implemented as `make generate-proto-elixir` (plus `install-protoc-gen-elixir` bootstrap and `verify-proto-elixir` CI drift guard) in the top-level `Makefile`; pinned to `protobuf` hex `0.16.0` to match `elixir/serviceradar_core/mix.exs`. Module namespaces are derived from each proto's `package` directive (e.g. `Flowpb.*`, `Core.*`, `Camera.*`, `Identitymap.V1.*`), so `package_prefix` is intentionally omitted to preserve the existing `.pb.ex` layout. Target NOT wired into `build-binaries` so Go builds do not require Mix on PATH.

### 21. [Phase 4] Sidecar + bridge + UI

- [x] 21.1 **RETIRED CANARY HISTORY.** Implement `IngestExternalFlows` client-streamed RPC consumer in `netprobe`; production no longer sends external flows down this arm.
- [x] 21.2 **RETIRED CANARY HISTORY.** Annotate matched 5-tuples with PID / process / cmdline / uid / container-id; drop unmatched. Implemented by `rust/netprobe/src/attribution.rs` (`flow_to_pid` + `process_info` map readers with `/proc` enrichment), `rust/netprobe/src/external_flow.rs` (canonical 5-tuple matcher with unmatched/invalid drop paths), and `rust/netprobe/src/server.rs` (external-flow IPC ack + matched `FlowAttributionEvent` fan-out). Focused coverage: `external_flow`, `flow_attribution_event_caps_redacted_cmdline_to_contract`, and `ingest_external_flow_record_emits_matched_via_broadcast_and_bumps_counter`. This records the retired external-flow canary and is not a production routing requirement.
- [x] 21.3 Replace the experimental host-slice/Go bridge with the current agent-up/core-side join. The agent sends retained `FlowAttributionEventBatch` payloads through `StreamStatus`; agent-gateway authenticates and forwards them; `StatusHandler` derives agent/partition authority from that context and persists bounded rows in `platform.flow_process_attribution_current`; `ServiceRadar.FlowAttribution.Correlation` joins those rows to independently ingested OCSF NetFlow/IPFIX rows and stamps the match in place. The demo host-slice subscriber, static routes, and `flow.attributed.*` publication are retired and are not production dependencies. Coverage includes batch decoding, partition authority, exact bidirectional matching, protocol-specific fallback, and delayed arrival inside the correlation window.
- [x] 21.4 Add the "Attributed Flows" view to the Flows dashboard. Implemented as `/observability/flows/attributed`, reading OCSF Network Activity rows whose in-place payload is stamped `event_type = "attributed_flow"` and exposing their persisted process context.

---

## Phase 5 — Remote pcapng capture sessions (deferred)

> **SUPERSEDED 2026-09-02 by `add-remote-pcapng-capture`. Do not
> implement sections 22-28 from the text below.** Three of these tasks
> rest on a premise that is false in this repository: 22.3 ("compile the
> libpcap-style BPF filter via the `pcap` crate") and 22.4 ("open a
> dedicated pcap handle") assume libpcap, which no shipped netprobe build
> has -- `rust/netprobe/Cargo.toml:67` gates `pcap` behind the
> `remote-capture` cargo feature and `rust/netprobe/BUILD.bazel:11-15`
> returns `[]` for every platform, so Bazel always compiles the stub that
> bails with "pcap capture backend is not enabled in this build".
>
> The replacement captures via `AF_PACKET`/`PACKET_MMAP` with
> `SO_ATTACH_FILTER`, which is what libpcap itself does on Linux, needs no
> C dependency in the musl cross-build, and accepts Wireshark's compiled
> cBPF natively -- RPCAP carries a compiled BPF program, not a filter
> string, so an eBPF-based tap would have to interpret arbitrary cBPF
> inside an eBPF program and would not verify.
>
> The scope also grew: the end goal is that stock Wireshark can point at
> ServiceRadar over `rpcaps://`, with opt-in retention to the object
> store. The tasks below are kept as the record of what was originally
> specified. Tracked by GitHub #4025.

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
- [ ] 24.6 Enable AshPaperTrail on `RemotePacketCaptureSession`; ensure request, authorise, active, complete, abort, timeout, and deny transitions are performed through Ash actions with version metadata for actor, partition, request id, agent id, target interfaces, BPF filter metadata, duration, snaplen, byte cap, and bytes streamed. The request id must be explicit action context; missing request id fails validation rather than falling back to `Logger.metadata`.
- [ ] 24.7 Implement a `web-ng` streaming endpoint (Phoenix Channel) that authenticates the client (`add-cli-device-auth`), dispatches the request to `core-elx` over ERTS RPC for RBAC + audit + session-record creation, then proxies pcapng bytes between the client and `core-elx`.
- [ ] 24.8 Implement the `core-elx` side that brokers between `web-ng` and the `agent-gateway` command bus over ERTS RPC, counts bytes for the session record, and surfaces session state.
- [ ] 24.9 Implement client-disconnect detection at the `web-ng` edge: on stream close from the client side, propagate via ERTS RPC to `core-elx`, which sends `StopRemoteCaptureSession` to the agent and transitions state to `aborted`.
- [ ] 24.10 Implement tenant-level cap ceilings: configurable max `duration_s`, `byte_cap`, and concurrent sessions per partition.
- [ ] 24.11 Emit a durable standard audit event for denied invasive actions that intentionally do not create or mutate an Ash resource, including cross-partition remote capture attempts and malformed requests rejected before session creation.
- [ ] 24.12 Add tests proving AshPaperTrail versions are written for every `RemotePacketCaptureSession` transition and for packet-observation posture changes; add a denial test proving a standard audit event is written when no session resource is created.

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
- [ ] 28.5 Auditability E2E: start and stop a remote capture, then verify the standard audit feed renders AshPaperTrail-backed entries for request/start/stop with actor, partition, agent id, interfaces, BPF filter metadata, byte count, and termination reason.

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

## Phase 1 amendment — license-clean fingerprint stack

This amendment supersedes the `huginn-net` / p0f-via-huginn-net
portions of §1.4, §3, §4.1, §18.5, and §18.10. Original task
checkboxes remain marked complete for the work that shipped against
the prior spec; the tasks below replace that behaviour with the
license-clean stack per `design.md` D14 and the rewritten
`Passive OS fingerprinting via a license-clean stack` requirement in
`specs/host-network-visibility/spec.md`. The `huginn-net` *crate* is
removed (§31.7); the upstream LGPL-2.1 `p0f.fp` *signature corpus* is
retained as a separate replaceable data file and primary classifier
(§31.1–§31.4). JA4 base
(BSD-3-Clause, FoxIO patent-disclaimed) and HASSH (BSD-3-Clause)
land as confidence boosters (§31.5, §31.6). JA4T, JA4H, JA4S, JA4SSH,
JA4X are **not** implemented — FoxIO License 1.1 + patent-pending
posture is incompatible with ServiceRadar's commercial sale.

### 31. [Phase 1 amendment] License-clean fingerprint stack

- [x] 31.1 Vendor the p0f signature corpus under `rust/netprobe/p0f-corpus/`. Source upstream `p0f.fp` from `https://lcamtuf.coredump.cx/p0f3/releases/p0f-3.09b.tgz` (LGPL-2.1, preserved as a separate replaceable data file). Record source URL, last-modified date, tarball sha256, `p0f.fp` sha256, and the upstream LGPL text in `rust/netprobe/p0f-corpus/README.md` / `LICENSE-LGPL-2.1.txt`. Mark the upstream file as frozen-2014 so contributors know net-new signatures land in `serviceradar-additions.fp`, not the upstream file.
- [x] 31.2 Implement the in-tree `p0f.fp` parser at `rust/netprobe/src/p0f_corpus.rs`. Single file, ~300 LOC, zero external deps. Parses the documented p0f.fp grammar: `label:<class>:<name>:<flavor>` blocks followed by signature lines `ver:ttl:olen:mss:wsize,scale:olayout:quirks:pclass`, with `*` wildcards on every numeric field and the `+` window-modulo notation. Unit tests cover every wildcard form, the `+` modulo, malformed-line rejection, and round-trip parsing of the full upstream `p0f.fp`.
- [x] 31.3 Implement a `#![no_std]` p0f canonical-form encoder at `rust/netprobe/ebpf/src/p0f.rs` callable from the §18.5 kprobe. Input: the existing `TcpSynSignatureRecord` fields (`ttl`, `window_size`, `mss`, `options_layout`, `window_scale`, `ip_version`, `payload_class`, `quirks`). Output: a fixed-length byte array `[u8; 96]` carrying the canonical p0f form. Encoder MUST be verifier-safe: no heap, bounded options walk, no unbounded format-string formatting (hand-rolled decimal-to-ascii).
- [x] 31.4 Amend the §18.5 SYN-signature path to call `p0f::encode()` and emit a new `P0fRecord { version, flow_key, observed_ns, p0f_string: [u8; 96], p0f_len: u8 }` to a dedicated `p0f_signatures` ring buffer. Keep the existing `tcp_syn_signatures` ring buffer live for one minor version so the agent's Go bridge can migrate.
- [x] 31.5 Implement the userspace JA4 (base, TLS ClientHello) encoder at `rust/netprobe/src/ja4.rs`. Input: TLS ClientHello cipher suites, extensions, signature algorithms, and ALPN list — all extracted by the existing DPI TLS dissector. Output: canonical JA4 string per the BSD-3-Clause JA4 spec. Unit tests against the published JA4 reference vectors. Include a `LICENSE-JA4` file alongside that documents the BSD-3-Clause provenance and the FoxIO patent-disclaim statement quoted from `https://github.com/FoxIO-LLC/ja4`.
- [x] 31.6 Implement the userspace HASSH encoder at `rust/netprobe/src/hassh.rs`. Input: the SSH KEXINIT field lists from the existing DPI SSH dissector (kex_algorithms, server_host_key_algorithms, encryption_algorithms_client_to_server, encryption_algorithms_server_to_client, mac_algorithms_client_to_server, mac_algorithms_server_to_client, compression_algorithms_client_to_server, compression_algorithms_server_to_client). Output: HASSH (client) and HASSH-Server canonical strings per Corelight's maintained BSD-3-Clause fork of the Salesforce 2018 spec. Include a `LICENSE-HASSH` file documenting the BSD-3-Clause provenance.
- [x] 31.7 Drop the `huginn-net` dependency from `rust/netprobe/Cargo.toml` and `rust/netprobe/BUILD.bazel` `NETPROBE_DEPS`. Regenerate `crate_universe` via `bazel mod tidy`. Verify the static musl build still passes (`bazel build --platforms=//build/platforms:linux_x86_64_musl //rust/netprobe:netprobe`). Verify `cargo tree` shows no `huginn-net` node.
- [x] 31.8 Implement the p0f matcher at `rust/netprobe/src/p0f_matcher.rs`. Build a compile-time `phf::Map<P0fSignatureKey, P0fLabel>` from the §31.1 corpus via `phf_codegen` in `build.rs`. Wildcard signatures match via a fallback linear scan over a separate `&'static [(WildcardSignature, P0fLabel)]` slice (typically < 200 entries; linear is fine). Unit tests with at least 10 fixture SYNs per major OS family (Linux 2.6, Linux 5.x, Linux 6.x, Windows XP, Win10, Win11, macOS 14, macOS 15, FreeBSD 13, Solaris 11) plus negative cases.
- [x] 31.9 Implement the OS-match ensemble matcher at `rust/netprobe/src/os_matcher.rs`. The ensemble: (a) primary lookup is the §31.8 p0f matcher against the p0f canonical signature from the kprobe; (b) when JA4 (base) on the same flow agrees with the p0f match on OS family, boost confidence by a documented multiplier; (c) when HASSH on the same flow agrees with the p0f match on OS family, boost confidence by a documented multiplier; (d) when signatures disagree, emit the p0f match with disagreement metadata so operators can see and curate.
- [x] 31.10 Amend `proto/agent/netprobe/v1/netprobe.proto` `FingerprintEvent` to add a `LicenseCleanFingerprint { p0f_signature, p0f_match { label, name, version_flavor }, ja4, ja4_match { name, version_range }, hassh, hassh_server, hassh_match { name, version_range }, os_match { name, version_range, confidence }, agreement_count }` message. Mark the existing `TcpFingerprint`, `TlsFingerprint`, and `HttpFingerprint` variants as `deprecated = true` in proto comments; keep them populated for one minor version so the agent's Go bridge can migrate. Regenerate Go and Rust bindings; run `buf` lint.
- [x] 31.11 Rewire `rust/netprobe/src/fingerprint.rs` to consume the §31.4 `p0f_signatures` ring buffer (replacing the huginn-net SYN handler) and to call the §31.5 / §31.6 encoders from the DPI dissector callback path. Emit `FingerprintEvent` records carrying the new `LicenseCleanFingerprint` message, with single-signature confidence when only p0f fires, JA4-co-observed boost when TLS is present, HASSH-co-observed boost when SSH is present, and full-ensemble boost when all three agree.
- [x] 31.12 Rewrite §18.10 (was: "Rewire the userspace huginn-net matcher to consume the SYN-signature perf RB stream") to: "Wire the §31.9 OS-match ensemble to consume the §31.4 `p0f_signatures` ring buffer; one ensemble evaluation per matched SYN; emit `FingerprintEvent` per `design.md` D14." Mark §18.10 in source as `(amended)` once this lands.
- [x] 31.13 Add a CI lint at `.forgejo/workflows/tests-fingerprint-licensing.yml` that fails the build if `huginn-net`, `ja4t`, `ja4h`, `ja4s`, `ja4ssh`, `ja4x`, or any FoxIO-1.1-licensed crate appears anywhere in `cargo tree` output. Prevents accidental dependency drift into the encumbered space. Run on every PR.
- [x] 31.14 Amend `Ping`/`PingAck` to include the `p0f.fp` corpus revision, the `serviceradar-additions.fp` revision, and the JA4-base spec revision the sidecar was built against (replaces the prior `huginn-net` crate-version field). Update the agent's `StatusResponse` to surface all three.
- [x] 31.15 Update Phase 1 §3.6 and §3.7 pcap fixture tests (currently asserting `huginn-net`-style p0f matches): rewire to assert against the §31.8 in-tree p0f matcher. Carry forward at least one fixture per OS family.
- [x] 31.16 ServiceRadar-additions curation workflow: document in `rust/netprobe/p0f-corpus/CONTRIBUTING.md` how operators submit new p0f signatures for legacy gear we encounter (file path, format, review SLA, license — ServiceRadar-authored additions default to CC0-1.0 unless a future entry explicitly states otherwise). Add a Makefile / script target that lints additions for grammar correctness before merge.
- [x] 31.17 Documentation: extend `BUILD.md` with the p0f corpus regeneration procedure (analogous to the §18.3 `vmlinux.h` procedure), the `serviceradar-additions.fp` curation procedure, and how to bump the JA4-base spec revision pinned. Add a `docs/docs/fingerprint-architecture.md` page explaining the license-clean stack and why we don't implement JA4+ (linking to FoxIO's published license terms so the explanation stays current).
- [x] 31.18 Validation gate before declaring the amendment complete: (a) every signature in upstream `p0f.fp` parses without error; (b) every signature in `serviceradar-additions.fp` parses without error; (c) the p0f matcher correctly identifies a Linux 2.6, Linux 5.x, Windows XP, Win10, macOS 14, FreeBSD 13, and Solaris SYN from a fixture pcap; (d) the JA4 encoder matches a reference TLS ClientHello fixture bit-for-bit against the BSD-3 reference implementation; (e) the HASSH encoder matches Corelight/Salesforce reference vectors; (f) the ensemble matcher emits boosted confidence on a fixture flow that produces p0f + JA4 + HASSH all agreeing on the same OS family; (g) `bazel build` of the static musl binary no longer links libpcap or huginn-net (`ldd` clean + `cargo tree` shows no `huginn-net`, `ja4t`, `ja4h`, `ja4s`, `ja4ssh`, or `ja4x` nodes); (h) `Ping`/`PingAck` round-trip returns all three corpus revisions.

## Phase 1 amendment — multi-corpus fingerprint ensemble

This amendment supplements §31 with additional separately licensed
fingerprint corpora — **MuonFP** (Censys, MIT) on the TCP
axis alongside p0f, **Recog** (Rapid7, BSD-2-Clause-Views) on the
banner axes fed by existing DPI dissectors, and **Satori**
(xnih/satori, GPLv2 data corpus) across TCP / DHCP / DNS / SMB / SSH /
SSL / HTTP / browser / ICMP / NTP / SIP axes fed by existing eBPF/DPI
surfaces plus a new DHCP DPI dissector. See `design.md` D15 for
rationale and the licensing audit. Combined audited corpus reach jumps
from ~400 signatures (§31 alone) to ~7,000 across ~8 independent
observation axes.

### 32. [Phase 1 amendment] Multi-corpus fingerprint ensemble

- [x] 32.1 Audit and vendor the MuonFP format reference under `rust/netprobe/muonfp-corpus/`. Pull from `https://github.com/sundruid/muonfp` at a pinned commit. Record source URL, commit SHA, sha256 of the format/reference files, the upstream MIT LICENSE, and the audit finding that the pinned upstream tree contains no standalone signature corpus under `rust/netprobe/muonfp-corpus/README.md`. Verify no transitive dependency on FoxIO / JA4+ in either the reference files or companion code.
- [x] 32.2 Vendor the Recog corpus under `rust/netprobe/recog-corpus/`. Pull from `https://github.com/rapid7/recog` at a pinned release. Record source URL, release tag, sha256 manifest of all `xml/` files, and preserve the Rapid7 LICENSE / COPYING files verbatim (the pinned release has no separate NOTICE file). Establish a quarterly upstream-bump SOP documented in `rust/netprobe/recog-corpus/README.md`.
- [x] 32.3 Vendor the full Satori XML corpus under `rust/netprobe/satori-corpus/`. Pull from the maintained `https://github.com/xnih/satori` upstream at commit `73fa88fe6549995c68760be10631382df4ec1d1c`. Record source URL, commit SHA, sha256 of every `fingerprints/*.xml` file, and preserve the upstream GPLv2 LICENSE and README. Vendor only the fingerprint XML data; do not vendor or copy the Python runtime, pcap integration, or SSL/JA4 code.
- [x] 32.4 Implement the Recog XML parser at `rust/netprobe/build.rs` extension (build-time) and `rust/netprobe/src/recog.rs` (runtime). Build-time: parse all `xml/*.xml` files using `quick-xml`, extract `<fingerprint pattern="...">` regex patterns and their associated `<param name="..." value="..."/>` labels, codegen into compile-time `regex-automata::dfa::regex::Regex` instances grouped by service (HTTP-server, SSH-banner, SMB-version, FTP-banner, Telnet-banner, SNMP-banner, SIP-banner, RDP-banner, DNS-version). Runtime: provide a `fn match_recog(service: RecogService, banner: &str) -> Option<RecogLabel>` API. Unit tests against published Recog reference vectors for each service.
- [x] 32.5 Implement the Satori XML parser + matcher at `rust/netprobe/src/satori.rs`. Runtime-load all `rust/netprobe/satori-corpus/xml/*.xml` files from a configurable corpus directory into lookup structures keyed by Satori axis and canonical test fields; do not use `include_bytes!`, `include_str!`, generated Rust constants, or any other compile-time embedding for the GPLv2 XML corpus. Runtime: expose axis-specific match APIs for TCP, DHCP/DHCPv6, DNS, ICMP, NTP, SIP, SMB/browser, SSH, SSL/TLS, HTTP server, and HTTP user-agent observations. Unit tests with at least 5 DHCP device-class fixtures plus representative TCP / SSH / SMB / HTTP / user-agent fixtures from the vendored XML.
- [x] 32.6 Implement the MuonFP encoder/matcher at `rust/netprobe/src/muonfp.rs`. Use the §32.1 vendored format reference to encode observed TCP SYNs into MuonFP canonical form. Because the pinned upstream tree has no standalone signature corpus, do not add an upstream crate dependency or pretend label lookup exists; instead expose exact/wildcard rule parsing plus observed-signature emission so a future ServiceRadar-owned or upstream corpus can supply labels without new kernel surface. Unit tests cover the upstream spec vectors and at least 10 fixture SYNs per major OS family for stable canonical encoding.
- [x] 32.7 Wire MuonFP into the §31.9 OS-match ensemble at `rust/netprobe/src/os_matcher.rs` as a *parallel* TCP matcher alongside p0f. When both match, the ensemble carries both labels; when only one matches, the ensemble carries the one that fired. When MuonFP and p0f disagree on OS family, emit both with disagreement metadata; the §31.13 metrics surface flags `p0f_vs_muonfp_disagreement_total` so we can spot corpus-drift across the two.
- [x] 32.8 Add the Satori-specific observation plumbing. Add a DHCP/DHCPv6 DPI dissector at `rust/netprobe/src/dpi/dhcp.rs` for ports 67/68 and 546/547; it emits only canonical option ordering/presence, never DHCP option values. Reuse existing eBPF/DPI observations for Satori's TCP, DNS, ICMP, NTP, SIP, SMB/browser, SSH, SSL/TLS, HTTP server, and HTTP user-agent axes where those observations already exist or are introduced by the §32 Recog/banner work. No Satori Python runtime or pcap code is permitted.
- [x] 32.9 Wire Recog into the existing DPI dissector callbacks. Each dissector (HTTP/1, SSH, FTP, Telnet, SMB, SNMP, SIP, RDP, DNS) already extracts the banner string; on extraction, the dissector calls `recog::match_recog(<service>, <banner>)` and attaches the result to the per-flow fingerprint state. The §31.11 `fingerprint.rs` aggregator then includes the Recog match in the emitted `LicenseCleanFingerprint`. Note: the DPI dissectors currently emit `DpiEvent` records under §16; the Recog match is added as a sidecar attachment to those events, NOT a new event channel, to preserve the §16.3 privacy contract.
- [x] 32.10 Extend the §31.9 ensemble matcher to fuse Recog and Satori labels alongside p0f / MuonFP / JA4 / HASSH. Documented ensemble logic: (a) start with the highest-confidence TCP match (p0f, MuonFP, or Satori-TCP); (b) for each agreeing co-observation (JA4 / HASSH / Recog-HTTP / Recog-SSH / Recog-SMB / Satori-DHCP / Satori-HTTP / Satori-SSH / Satori-SMB / Satori-SSL / Satori-DNS / Satori-ICMP / Satori-NTP / Satori-SIP), multiply confidence by a per-axis factor documented in `os_matcher.rs`; (c) cap confidence at `1.0`; (d) record `agreement_count` (total number of agreeing axes); (e) on disagreement, fall back to majority vote across axes weighted by axis-confidence baseline.
- [x] 32.11 Extend `proto/agent/netprobe/v1/netprobe.proto` `LicenseCleanFingerprint` with: `muonfp { signature, label }`, `recog_http { product, version, os_family }`, `recog_ssh { product, version, os_family }`, `recog_smb { product, version, os_family }`, `recog_ftp { product, version, os_family }`, `recog_telnet { product, version, os_family }`, `recog_snmp { product, version, os_family }`, `recog_sip { product, version, os_family }`, `recog_rdp { product, version, os_family }`, `recog_dns { product, version, os_family }`, `repeated satori_matches { axis, signature, label, device_class, os_family }`, and per-axis observation booleans including `dhcp_observed`. Mark the §31.10 `LicenseCleanFingerprint` shape as `version = 2` in proto comments; v1 carriers remain valid one minor version. Regenerate Go / Rust bindings; run `buf` lint.
- [x] 32.12 Extend `Ping`/`PingAck` and the agent's `StatusResponse` to report the MuonFP corpus revision, Recog corpus revision, Satori corpus revision, and (when ServiceRadar additions land) the `serviceradar-recog-additions.xml` revision. Replaces and extends §31.14.
- [x] 32.13 Extend the §31.13 CI license-lint to *positively assert* that all newly-added fingerprint corpora trace to one of: LGPL-2.1 for the separately replaceable upstream p0f corpus, GPLv2 for separately replaceable Satori XML data, public domain / CC0 for ServiceRadar-authored additions, MIT, BSD-2-Clause / BSD-2-Clause-Views, BSD-3-Clause, or Apache-2.0. Any other license fails the lint. Catches accidental introduction of incompatible corpora (PRADS code, Nmap NPSL, fingerbank API-restricted, etc.), FoxIO-1.1-encumbered methods, and any `include_bytes!` / `include_str!` embedding of the GPLv2 Satori XML corpus.
- [x] 32.14 ServiceRadar Recog additions curation workflow: document in `rust/netprobe/recog-corpus/CONTRIBUTING.md` how operators submit new fingerprints for legacy / niche service banners we encounter. Additions land in `serviceradar-recog-additions.xml` (mirroring the §31.16 p0f additions pattern). Linter validates XML grammar + license header before merge. Quarterly upstream-bump SOP documents how to merge new Rapid7 releases without losing local additions.
- [x] 32.15 Documentation: extend `BUILD.md` with the regeneration procedures for all five corpora (MuonFP / Recog / Satori in addition to §31.17's p0f and JA4). Extend `docs/fingerprint-architecture.md` to describe the multi-corpus ensemble, the per-axis confidence weighting, and the Satori GPLv2 data-corpus boundary for all vendored Satori XML files. Include the corpus-coverage matrix from D15 in the documentation.
- [x] 32.16 Validation gate before declaring the §32 amendment complete: (a) every fingerprint in upstream MuonFP, Recog, and every vendored Satori XML corpus parses without error; (b) the MuonFP matcher correctly classifies a Linux, Windows, macOS, and FreeBSD SYN against fixture pcaps; (c) the Recog matcher correctly classifies an Apache 2.4 / nginx 1.18 / OpenSSH 8.9 / Samba 4.13 / Cisco IOS Telnet banner; (d) the Satori matcher correctly classifies representative TCP, DHCP, SSH, SMB, HTTP server, and user-agent fixtures from the vendored XML; (e) the ensemble matcher produces highest-tier confidence on a fixture flow producing p0f + MuonFP + Recog-HTTP + JA4 all agreeing on `Ubuntu 22.04`; (f) `cargo tree` shows no `huginn-net`, `ja4t`, `ja4h`, `ja4s`, `ja4ssh`, `ja4x`, or any GPL-/NPSL-licensed code crate; (g) static-musl binary size impact <= 6 MiB total for the compiled permissive corpora and matchers (Recog DFA-compiled + p0f + MuonFP + JA4 + HASSH), while Satori XML remains runtime-loaded from a separately replaceable corpus directory and is absent from `strings serviceradar-netprobe`; (h) `Ping`/`PingAck` round-trip returns all 5+ corpus revisions; (i) the new DHCP DPI dissector emits `DpiEvent`s without leaking DHCP option values (verified by inspection + a privacy-redaction unit test).

## Phase 1 amendment — active banner-grab phase in sweep service

This amendment adds an opt-in active banner-grab phase to the
existing **sweep service** (`go/pkg/scan/`, NOT the SNMP/API-focused
mapper at `go/pkg/mapper/`). The phase runs after the SYN half-open
scanner identifies live `(host, port)` pairs and emits
`BannerObservation` records that the agent forwards to netprobe in
bounded batches over a new `MatchBanners` IPC method. Netprobe matches
the supplied observations against the §32 Recog / Satori corpora and
returns labels; the agent emits or forwards the resulting
`FingerprintEvent`s. No corpus duplication, no shared Rust/Go crate, no
cgo. Banner grab is a streaming enrichment pipeline over SYN-confirmed
open ports, not a second in-memory scanner; preserve the SYN half-open
scanner's large-inventory latency profile while allowing exhaustive
active probing when operators choose that trade-off. HTTPS/TLS evidence
stays in the passive TLS/SSL fingerprint pipeline rather than active
HTTPS decryption. See `design.md` D16 for the architectural rationale.

### 33. [Phase 1 amendment] Active banner-grab phase in sweep service

- [x] 33.1 Extend `elixir/serviceradar_core/lib/serviceradar/network_discovery/sweep_profile.ex` (or equivalent Ash resource owning sweep configuration) with a `banner_grab` embedded resource. Fields: `enabled: boolean (default false)`, `protocols: {:array, :atom} default []` (subset of `[:ssh, :http, :smb, :ftp, :telnet, :smtp, :ntp, :dns, :rdp]`; HTTPS intentionally excluded), `ports: :map default %{}` (per-protocol port lists), `connect_timeout_ms: integer default 2000`, `read_timeout_ms: integer default 2000`, `max_banner_bytes: integer default 1024`, `max_concurrency_per_host: integer default 4`, `max_global_concurrency: integer default 256`, `max_probe_rate_per_second: integer default 0` (0 = unlimited beyond concurrency), `max_candidate_queue: integer default 8192`, `match_batch_size: integer default 256`, `match_batch_max_bytes: integer default 1048576`, `min_reprobe_interval_s: integer default 86400`, `per_host_rate_limit_ms: integer default 100`. Add Ash validations enforcing sensible bounds (timeouts ≤ 30s, max_banner_bytes ≤ 64 KiB, concurrency ≤ 4096, max_probe_rate_per_second ≤ 50000, max_candidate_queue ≤ 1_000_000, match_batch_size ≤ 4096, match_batch_max_bytes ≤ 4 MiB).
- [x] 33.2 Add an Ash migration for the new `banner_grab` fields; verify it applies cleanly with `mix ash.migrate`.
- [x] 33.3 Add Ash policy: `banner_grab.enabled` cannot be flipped to `true` without the operator-role permission `networks.sweeps.banner_grab` (new — see §33.7). Read access is unrestricted (so operators can audit profiles).
- [x] 33.4 Plumb the new fields through the Elixir → gateway compiler so they appear in the sweep config JSON delivered to the agent. The gateway-side schema lives at `elixir/serviceradar_core/lib/serviceradar/agent_config/sweep_compiler.ex` (or equivalent — implementer to verify).
- [x] 33.5 Extend the Go-side sweep config parser (`go/pkg/agent/sweep_config_gateway.go` or equivalent) to deserialise the new `banner_grab` block. Populate a new `SweepConfig.BannerGrab` struct mirroring the Ash shape.
- [x] 33.6 Create `go/pkg/scan/banner_grab/` directory with the following files: `engine.go` (the phase orchestrator), `candidate_planner.go` (streaming SYN-result filtering, freshness gate, error backoff, bounded candidate queue, checkpoint/progress counters), `observation.go` (the `BannerObservation` struct + serialisation), `batcher.go` (bounded `MatchBanners` batching by count / bytes), `rate_limit.go` (per-host + global concurrency + optional probe-rate limiters), `ssh.go`, `http.go`, `smb.go`, `ftp.go`, `telnet.go`, `smtp.go`, `ntp.go`, `dns.go`, `rdp.go`. Each protocol module exports `Probe(ctx, host string, port int, opts ProbeOpts) (BannerObservation, error)` with the behaviour documented in `design.md` D16's per-protocol table. Do not add active HTTPS decryption to this phase.
- [x] 33.6a Audit, benchmark, and tune the Go full-connect engine before banner grab depends on it at fleet scale. Current `go/pkg/scan/tcp_scanner.go` uses a fixed `net.Dialer.DialContext` worker pool with default 500-worker concurrency and a 5-second timeout, but it still has a slice-based `Scan(ctx, []Target)` surface and result buffering proportional to target count. Add a deterministic benchmark / profiling harness for (a) 50k hosts across the representative banner-grab port set and (b) 1M synthetic candidates, using a fake dialer or loopback fixture so CI does not require a real large network. Verify memory is O(concurrency + bounded queues + match batch size), active dials never exceed configured concurrency, candidate generation is streaming, and the path does not materialize the full inventory or buffer all results. Compare historical low-concurrency settings against current and tuned defaults, document elapsed time / throughput / timeout distribution, and expose agent metrics for active dials, dial start rate, full-connect queue depth, timeouts, resets, and resource-exhaustion errors (fd / ephemeral-port pressure when detectable).
- [x] 33.7 Add `networks.sweeps.banner_grab` permission to the RBAC catalog at `elixir/serviceradar_core/lib/serviceradar/identity/rbac/catalog.ex` alongside the existing `networks.sweeps.run` permission. Default-assigned to the `operator` role.
- [x] 33.8 Add a new batched IPC method to the netprobe IPC at `proto/agent/netprobe/v1/netprobe.proto`: `MatchBanners(BannerBatch) -> BannerMatchBatch` over the existing length-prefixed UDS frame protocol. Messages: `BannerObservation { uint64 observation_id, string host, uint32 port, string protocol, bytes banner_bytes, int64 observed_at, string source }`, `BannerBatch { repeated BannerObservation observations }`, `BannerMatch { uint64 observation_id, string corpus_label, string os_family, string product, string version, double confidence, string raw_pattern_id }`, and `BannerMatchBatch { repeated BannerMatch matches }`. Preserve input ordering where possible and always preserve `observation_id`. Regenerate Go / Rust bindings; run `buf` lint.
- [x] 33.9 Implement `MatchBanners` on the netprobe side (Rust) at `rust/netprobe/src/ipc/match_banner.rs`. The handler delegates to the §32 Recog matcher for HTTP / SSH / SMB / FTP / Telnet / SMTP / SIP / RDP / DNS protocols and to the §32 Satori matcher for any matching Satori banner axis (including HTTP server / user-agent, SSH, SMB, SIP, DNS, and NTP observations). It MUST NOT open outbound sockets and MUST NOT rely on passive eBPF sniffing of the sweep connection. Return the highest-confidence match per observation or `BannerMatch { corpus_label: "unknown", confidence: 0 }`. Unit tests with fixture banners for each protocol plus a batch-order / observation-id preservation test.
- [x] 33.10 Wire the banner-grab phase into the sweep service at `go/pkg/agent/sweeper.go` (or equivalent — implementer to verify). The phase runs after `syn_scanner.Sweep()` returns the live-target stream. Concurrency: a worker pool bounded by `max_global_concurrency`; per-host queue bounded by `max_concurrency_per_host` with a `per_host_rate_limit_ms` floor between consecutive connects to the same host; global start rate optionally bounded by `max_probe_rate_per_second`; candidate buffering bounded by `max_candidate_queue`; fresh targets skipped until `min_reprobe_interval_s` expires unless operator refresh is requested. The implementation may process every eligible candidate in the cycle; it must not materialize an unbounded full-inventory worklist.
- [x] 33.11 Wire the agent → netprobe `MatchBanners` call into the banner-grab phase output handler. The phase pushes each successful `BannerObservation` to a bounded match queue; a batcher goroutine flushes by `match_batch_size`, `match_batch_max_bytes`, or short timer and invokes `netprobeSidecar.MatchBanners(ctx, batch)` over the existing UDS. Results flow back into the existing `MapperResultPublisher` / `SweepResultPublisher` as enrichment on the canonical device record (verify which publisher the sweep service uses today and extend that one).
- [x] 33.12 Surface banner-grab outcomes in agent status. Add counters `sweep_banner_grab_candidates_total`, `sweep_banner_grab_probes_total`, `sweep_banner_grab_inflight`, `sweep_banner_grab_queue_depth`, `sweep_banner_grab_match_batches_total`, `sweep_banner_grab_match_batch_bytes_total`, `sweep_banner_grab_skipped_fresh_total`, `sweep_banner_grab_skipped_backoff_total`, `sweep_banner_grab_matches_total`, `sweep_banner_grab_empty_response_total`, `sweep_banner_grab_connection_reset_total`, `sweep_banner_grab_timeout_total`, exposed via the existing Prometheus surface on the agent's localhost metrics port.
- [x] 33.13 Add capability advertisement logic at `go/pkg/agent/push_loop.go` (the existing capability computation site found by the deep-dive). Advertise `sweep.banner_grab = available` only when (a) at least one sweep profile has banner_grab enabled, (b) the netprobe sidecar is running and healthy, and (c) netprobe reports the Recog corpus loaded (via a new field in `PingAck`). Otherwise advertise `sweep.banner_grab = unavailable` with a `reason` field.
- [x] 33.14 Extend `Ping`/`PingAck` per §32.12: add a `recog_corpus_loaded: bool` field so the agent can gate capability advertisement on actual corpus availability, not just netprobe liveness.
- [x] 33.15 Add AshPaperTrail entry on the parent sweep-job record when a banner-grab phase completes. Entry summary: probe count, banner-match count, empty-response count, error count, total bytes received. Individual probes do NOT produce per-probe audit entries (volume management); they log via the structured logger at info level instead.
- [x] 33.16 Extend the `DeviceDiscoveryIngestor` at `elixir/serviceradar_core/lib/serviceradar/inventory/device_discovery_ingestor.ex` to consume the `source = sweep_active` `FingerprintEvent`s flowing back from netprobe. Merge banner-derived OS / vendor / product / version evidence into the canonical Device record's `os.active_fingerprint` (parallel to the existing `os.passive_fingerprint` field). Append `discovery_sources` with `"sweep_active"`.
- [x] 33.17 Add the "Banner grab" section to the web-ng `SweepProfile` editor at `elixir/web-ng/lib/web_ng_web/live/sweep_profile_live/form.ex` (or equivalent — implementer to verify the actual LiveView path). Sections: enable toggle, protocol checkboxes, per-protocol port-list inputs, timeouts, max_banner_bytes, concurrency caps, optional max probe rate, candidate queue bound, match batch size / bytes, and min re-probe interval. Include a "preview outbound traffic" panel showing estimated connects and elapsed time for the current inventory under the configured concurrency / timeout settings. Gated by the `networks.sweeps.banner_grab` Permit.Phoenix.LiveView policy.
- [x] 33.18 Add the "Active fingerprint" subtab to the Device Detail view at `elixir/web-ng/lib/web_ng_web/live/device_live/detail.ex` (or equivalent). The subtab shows banner-grab outcomes per port: matched OS / vendor / product / version, source profile + sweep cycle, last observed timestamp. Operator-only view; sensitive fields (raw banner bytes) gated behind the existing `metadata.raw_banner` privacy-opt-in flag.
- [x] 33.19 Operator runbook addition at `docs/docs/sweep-banner-grab.md`: when to enable banner-grab, recommended port allowlists per environment, why HTTPS/TLS is handled by passive fingerprinting instead of active banner grab, IDS / IPS whitelisting guidance for the agent source IP, expected outbound traffic volume and elapsed-time estimates for 20k / 50k / 100k / 1M inventories under representative concurrency and timeout settings, troubleshooting (`sweep.banner_grab = unavailable` reasons), opt-out procedure.
- [x] 33.20 Integration test (`go/pkg/scan/banner_grab/integration_test.go`): spin up a netprobe sidecar with the §32 Recog corpus loaded, run a banner-grab phase against a fixture network (Docker compose with OpenSSH, nginx, Postfix, Samba containers), assert that (a) live ports get probed, (b) banners are captured, (c) `MatchBanners` returns the expected OS/product labels, (d) `FingerprintEvent`s with `source = sweep_active` propagate to the agent's status push, (e) the canonical Device record in core-elx gains `os.active_fingerprint` after ingestion.
- [x] 33.21 Validation gate before declaring the §33 amendment complete: (a) `banner_grab.enabled = false` is the default and produces zero outbound banner-grab traffic; (b) `banner_grab.enabled = true` with `protocols = [:ssh]` and `ports.ssh = [22]` against a /28 fixture network produces exactly N probes where N is the number of live, fresh-eligible port-22 endpoints from the prior SYN scan; (c) a synthetic 1M-host sweep with 500k eligible open ports keeps active sockets ≤ `max_global_concurrency`, candidate queue depth ≤ `max_candidate_queue`, and processes all eligible candidates without materializing a 1M-entry worklist; (d) port 443 is not actively TLS-decrypted by banner grab and TLS/SSL evidence remains in the passive fingerprint pipeline; (e) capability advertisement correctly transitions to `unavailable` when netprobe is stopped mid-sweep; (f) connection reset / read timeout / partial banner each increment the correct counter without inflating the error counter; (g) audit-trail entry on the sweep-job record correctly summarises probe counts; (h) the new `MatchBanners` IPC method round-trips a 256-observation SSH/HTTP batch within the configured p99 target on a development laptop; (i) `web-ng` SweepProfile editor renders the new section without breaking existing profile CRUD; (j) the §33.6a full-connect benchmark demonstrates no historical 19-hour-style regression for 50k hosts across representative banner ports and proves bounded memory / socket / goroutine behaviour for 1M synthetic candidates.
