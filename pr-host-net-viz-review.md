# `add-host-network-visibility-sidecar` — Live Code Review

**Branch:** `feat/passive-device-fingerprinting`
**Proposal:** `openspec/changes/add-host-network-visibility-sidecar/`
**Reviewer role:** independent quality gate against the OpenSpec proposal + design + spec deltas. Implementation owned by another agent.

This is a **live document**. Each review pass appends to the pass log at the bottom and updates the severity sections in place. Severity buckets: **Blocker** (must fix before Phase 1 ships), **Major** (should fix in Phase 1 or before next phase starts), **Minor** (nice-to-have for Phase 1, must-have before GA), **Nit** (taste / micro-optimisation).

Every finding cites `path:line` and, where applicable, maps to a specific requirement in the spec deltas.

---

## Implementation Resolution Log

This section records fixes made after the review text below was written. Some
older findings remain in their original sections for auditability, but are no
longer open.

| Finding | Status | Commit | Notes |
|---|---|---|---|
| Pass 1 B-2 | Resolved | `5738c0030` | Added Bazel-driven netprobe Rust test coverage to CI while bootstrapping libpcap on Linux runners. |
| Pass 2 M-5/M-7 | Resolved | `e566eca0f` | Closed the netprobe client event close race and preserved stream delivery safety. |
| Pass 2 M-8/Mi-? | Resolved | `35ef59648` | Moved sidecar IPC/config paths under private runtime directories. |
| Pass 3 M-10 | Resolved | `52e35ced0` | Passive fingerprint hash tokens now include field context to avoid swapped-field collisions. |
| Pass 3 M-12 | Resolved | `33639d344` | Fingerprint capability is advertised as enabled only when the netprobe sidecar is healthy; unavailable sidecars no longer register passive discovery. |
| Pass 3 M-14 | Resolved | `52e35ced0` | Sparse OS passive fingerprint evidence is retained when family/version/confidence exists. |
| Pass 3 Mi-24 | Resolved | `8b1e59ec7` | Empty-but-observed passive protocol payloads now retain an `observed: true` marker. |
| Pass 3 Mi-25 | Resolved | `8b1e59ec7` | Removed the redundant `infer_os/3` function head. |
| Pass 3 Mi-28 | Resolved | `33639d344` | Discovery-source registration now checks the exact `host-network-visibility.fingerprint.enabled` capability. |
| Pass 3 Mi-29 | Resolved | `e79e980d4` | Removed unreachable underscore-form Agent Detail capability fallbacks. |
| Pass 3 M-11 | Resolved | `1d8b28731` | Phase 1 spec/docs now describe the libpcap-enabled dynamic Linux package, deb/rpm declare libpcap, and the Alpine agent rootfs bundles glibc/libpcap while musl static remains a build target. |
| Pass 3 Mi-27 | Resolved | `1d8b28731` | VisibilityProfile create/update rejects reserved DPI, flow attribution, and process snapshot fields until later phases. |
| Pass 3 Mi-30 | Resolved | `1d8b28731` | `register_identifiers/3` no longer persists passive fingerprint hashes as `DeviceIdentifier` rows. |
| Pass 3 Mi-31 | Resolved | `1d8b28731` | Visibility profile migration now uses `:integer` for `priority`, matching the Ash resource. |
| Pass 3 M-13 | Investigated | `4af4bda1a` | Added the missing `identity_wheres_to_sql` metadata that blocked Ash codegen at `RemoteAccessRequest`; `mix ash.codegen add_visibility_profile --dry-run` now runs but reveals broad pre-existing snapshot drift outside this proposal, so the VisibilityProfile migration remains open for a dedicated Ash migration cleanup. |
| Pass 3 N-11 | Resolved | `0c1229a46` | Split the 1122-line Visibility Profiles LiveView into a 429-line event/persistence LiveView plus component, form-state, and target-query-builder modules. |
| Pass 3 N-13 | Resolved | `4af4bda1a` | Agent capability status keeps sidecar state only in the JSON `Message` payload used by `GatewayServiceStatus` and no longer also sets `StatusResponse.Sidecars`. |
| Pass 3 N-14 | Resolved | `4af4bda1a` | Agent postinstall now emits one canonical netprobe capability remediation message for both `setcap` failure paths. |
| Phase 1 §4.2/§4.3 | Resolved | current batch | Added pinned Buf lint config/Makefile target, wired proto lint into Go CI, added netprobe Go generation to `make generate-proto`, and documented the checked-in Go plus build-time Rust Prost binding paths in the OpenSpec task list. |
| Pass 1 M-3 | Resolved | current batch | `TcpFingerprint` now carries structured TTL, window, MSS, option layout, quirks, IP version, window scale, and payload-class fields; Rust populates them and Go translation preserves them in metadata. |
| Pass 2 M-6 | Resolved | current batch + follow-up | Sidecar public state now uses the spec enum in steady state (`running`); extra `healthy` and unused `failed` states were removed. |
| Pass 2 M-8/M-9 | Resolved | current batch | Agent config poll/control-stream paths now write the bootstrap allowlist, start/stop the persistent netprobe sidecar, call `ApplyConfig` before accepting the config version/ack, drain fingerprint events, and only emit `OnUnhealthy` at the failure-threshold edge. |
| Pass 3 Mi-32 + Pass 4 T-12 | Resolved | current batch | Visibility profiles now persist operator-curated `capture_interfaces`; compiler output carries them into `VisibilityConfig`; capability advertisement stays unavailable when visibility is disabled or has no capture work. |
| Pass 4 Mi-33 | Resolved | current batch | Removed the dead passive-fingerprint hash machinery and its dedicated test after passive fingerprints stopped being persisted as `DeviceIdentifier` rows. |
| Pass 4 Mi-35 | Resolved | current batch | OpenSpec now requires explicit Ash action request id context for invasive operator actions and fail-closed behavior instead of `Logger.metadata` fallback. |
| Pass 1/2 minor+nits sweep | Resolved | current batch | Addressed active-client panic cleanup, lagged-event metrics, CAP_NET_RAW comment, reduced snaplen, pcap packet timestamps, duplicate binding warnings, disabled default fingerprint config, parallel shutdown, orphan `etherparse`, static binary `--help` smoke, disabled-capture startup, no-rate-limit bucket writes, stable config hash, JSON log timestamps, allowlist validation reuse, flaky backoff defaults, `cmd.Cancel` nil no-op, larger log scanner buffer, compiler lookup caching, `strconv.FormatUint`, nanosecond sidecar health timestamps, SNI sanitization, first-probe context handling, restart-count capping, and added enrichment rules. |
| Phase 1 §13.6 / §15.5 | Deferred | skipped by request | Kind smoke and E2E remain unchecked by explicit instruction to skip E2E before merge; all code-surface review gates above are resolved. |

---

## Pass 1 — 2026-05-27

**Coverage:** commits `23213af..b4cbf9d` (8 commits), plus uncommitted state. Touches tasks §1, §2, partial §3 (3.1, 3.3, 3.4, 3.5 — 3.2/3.6/3.7 still open), partial §4 (4.1, 4.4 — 4.2/4.3 still open). Tasks §5 onward (Go sidecar runtime, bridge, agent config delivery, Ash, UI, packaging) are unimplemented and out of scope for this pass.

**Files reviewed:**
- `rust/netprobe/Cargo.toml`, `BUILD.bazel`, `build.rs`
- `rust/netprobe/src/{main,capabilities,capture,config,fingerprint,framing,lifecycle,metrics,proto,runtime_config,server}.rs`
- `proto/agent/netprobe/v1/{netprobe.proto,BUILD.bazel}` (generated `.pb.go` not line-reviewed)
- `MODULE.bazel`, `.bazelrc`, `.cargo/config.toml`, `BUILD.md`
- `build/platforms/BUILD.bazel`, `build/toolchains/BUILD.bazel`, `build/rust/BUILD.bazel`
- `.forgejo/workflows/tests-rust.yml`, `scripts/ci/ensure-forgejo-tools.sh`

**Verdict:** Foundation is solid and the patterns chosen (single-client UDS, framed protobuf, broadcast-channel fan-out, leak-the-database for `'static`, `tokio` + thread mix for blocking pcap, capability assertion before pcap before privilege drop) all match the design. Tests are present for the non-fingerprint surfaces. **Two findings are blockers** that need to be addressed before the Phase 1 binary can be considered functional: (1) the shipping `musl` binary disables packet capture; (2) the Rust test suite is never run in CI.

### Severity summary
| | Pass 1 |
|---|---|
| Blocker | **2** |
| Major | **4** |
| Minor | **11** |
| Nit | **5** |
| Tracking (spec-vs-impl gaps; not bugs) | 4 |

---

### Blockers

#### B-1. Shipping `musl` binary disables packet capture
**Files:** `rust/netprobe/BUILD.bazel:27-31, 45-49`, `rust/netprobe/Cargo.toml:10-11, 21`, `rust/netprobe/src/capture.rs:200-211`
**Spec mapping:** `host-network-visibility` — `Bundled host visibility sidecar binary`, `Passive fingerprinting via huginn-net`.

The `BUILD.bazel` `select()` strips the `pcap-capture` feature from `crate_features` and `deps` when the target platform is `linux_x86_64_musl` or `linux_aarch64_musl`:

```starlark
crate_features = select({
    "//build/platforms:target_linux_aarch64_musl": [],
    "//build/platforms:target_linux_x86_64_musl": [],
    "//conditions:default": ["pcap-capture"],
}),
```

`Cargo.toml` makes `pcap` an optional dependency gated by that feature, and `src/capture.rs:200-211` provides a no-op `start_capture_workers` when the feature is absent:

```rust
#[cfg(not(feature = "pcap-capture"))]
fn start_capture_workers(...) -> Result<CaptureWorkers> {
    Ok(CaptureWorkers {
        stop: Arc::new(AtomicBool::new(false)),
        threads: Vec::new(),
    })
}
```

The proposal mandates `serviceradar-netprobe` ship as a `musl` static binary and "MUST be statically linked against musl for `x86_64-unknown-linux-musl` and `aarch64-unknown-linux-musl`". CI green-lights the musl build today only because the static-link verification is structural (`file`, `readelf`); it never exercises the fingerprinting path. The build that gets packaged into the agent OCI image will start cleanly, accept `ApplyConfig`, respond to `Ping`, and silently emit zero events — matching the spec's "static binary" requirement on its face while failing the spec's primary functional requirement.

**Recommended remediation paths** (pick one):
1. Make `libpcap` link statically against musl. `pcap` crate can be built against `libpcap.a` if `LIBPCAP_LIBDIR`/`LIBPCAP_VER` are set and a static `libpcap.a` is present in the musl sysroot.
2. Replace the `pcap` capture path with a pure-Rust `AF_PACKET`/`PF_PACKET` raw-socket capture (the `nix` crate already a dep) — workable on Linux without any C dependency.
3. Drop the `select()` and require a working musl libpcap as a build-time prerequisite (document in BUILD.md). CI must then fail if the musl binary can't link `libpcap.a`.

**Note:** option 2 also unlocks Phase 3's eBPF integration since both paths share the same kernel surface.

#### B-2. Netprobe Rust tests never run in CI
**File:** `.forgejo/workflows/tests-rust.yml:49-56`

The matrix has two `rust/netprobe` entries, both `runner: bazel-static`. The `bazel-static` step only runs `bazel build`; it does not run `cargo test` or `bazel test`. There is no `runner: cargo` entry for `rust/netprobe`. As a result, every test module in the crate — `framing::tests` (frame round-trip + oversize rejection), `config::tests` (allowlist validation × 7), `runtime_config::tests` (gate logic × 3), `server::tests` (Ping/concurrent-client/streaming/ApplyConfig × 4), `capture::tests` (allowlist opener × 3), `lifecycle::tests` (privilege-drop ordering × 2), `fingerprint::tests` (engine emits/ignores + redaction × 4) — never runs.

Add a `rust/netprobe / runner: cargo` matrix entry alongside the bazel-static ones (or a `bazel test` variant). Otherwise this critical-path module ships with zero gate against regressions.

---

### Major

#### M-1. `drop_privileges` does not reset supplementary groups
**File:** `rust/netprobe/src/capabilities.rs:35-55`
**Spec mapping:** `host-network-visibility` — `Capability sequencing and privilege drop`, `Least-privilege sidecar execution`.

```rust
setgid(target.gid).with_context(|| format!("failed to set gid for {user}"))?;
setuid(target.uid).with_context(|| format!("failed to set uid for {user}"))?;
```

`setgid` replaces the primary GID but leaves the **supplementary group list** intact. When the process started as root, its supplementary groups include every group root is in (often `root`, `sudo`, `wheel`, `disk`, `adm`). After `setuid(target.uid)`, the new (non-root) UID inherits all of those memberships — silently granting access to files owned by those groups.

Before `setgid`/`setuid`, call `setgroups(target.gid, &[])` (or `nix::unistd::setgroups(&[Gid::from_raw(0)])` and then clear) to wipe the supplementary list. Many production-grade Rust dropping examples use `initgroups(user, target.gid)` to set the correct list for the target user.

#### M-2. Privilege drop is optional; spec says SHALL
**Files:** `rust/netprobe/src/main.rs:55-64`, `rust/netprobe/src/lifecycle.rs:26-28`
**Spec mapping:** `host-network-visibility` — `Capability sequencing and privilege drop`.

```rust
#[arg(long, env = "SERVICERADAR_NETPROBE_DROP_USER")]
drop_user: Option<String>,
...
fn drop_privileges(&mut self, user: Option<&str>) -> Result<()> {
    capabilities::drop_privileges(user)
}
```

If `--drop-user` is not set, `drop_privileges` returns `Ok(())` without changing UID. The spec requires the binary "SHALL drop to a non-root UID immediately after opening its packet capture handles and binding its IPC socket". Today a Phase 1 binary launched with no `--drop-user` (the default) runs to steady state as `root` and holds `CAP_NET_RAW` indefinitely — exactly what the spec is meant to prevent.

The dev escape hatch should be explicit and noisy: refuse to start as `uid==0` unless an explicit `--allow-root` (or rename of `--skip-cap-check`) is passed. Production deployments will always set `--drop-user` via systemd; this just prevents accidental privilege retention.

#### M-3. `TcpFingerprint` proto lacks structured p0f fields
**Files:** `proto/agent/netprobe/v1/netprobe.proto:97-102`, `rust/netprobe/src/fingerprint.rs:141-177`
**Spec mapping:** `host-network-visibility` — `Fingerprint event schema` (Scenario: TCP event contains p0f signature payload).

The spec scenario explicitly requires:

> THEN the event's `tcp` payload contains the p0f signature string, **TTL, window size, MSS, and option ordering as separate fields**

The proto today carries only `signature` (single opaque string), `os_family`, `os_name`, `confidence`:

```protobuf
message TcpFingerprint {
  string signature = 1;
  string os_family = 2;
  string os_name = 3;
  float confidence = 4;
}
```

The `huginn_net::huginn_net_tcp::output::SynTCPOutput.sig` already exposes `ttl`, `window`, `mss`, `options_layout`, `quirks`, `version`, `wsize_scale`, `payload_class` as structured fields. Add corresponding scalar/repeated fields to `TcpFingerprint` and populate them in `tcp_event(...)`. Without these the downstream enrichment matcher (`device-inventory` — `Passive Visibility Feeds Rule-Driven Vendor and Type Enrichment`) cannot key on individual signature components — only on a brittle opaque string.

#### M-4. `ApplyConfig.capture_interfaces` is validated but never propagated
**Files:** `rust/netprobe/src/runtime_config.rs:73-88`, `rust/netprobe/src/capture.rs:46-49`
**Spec mapping:** `host-network-visibility` — `Capture-interface allowlist with deny-by-default` (Scenario: New interface requires explicit opt-in).

`RuntimeConfig::apply` validates `config.capture_interfaces` and stores it in `VisibilityState`, but `CaptureHandles` is only opened once at startup from the **bootstrap config file** (`capture::CaptureHandles::open(config)` in `lifecycle.rs:22-24`). After startup no code path re-opens pcap based on the runtime config delivered via `ApplyConfig`.

Net effect: an operator who changes the allowlist via a `VisibilityProfile` push will see the new allowlist accepted by `ApplyConfig` (no error) but capture continues only on the original set. Worse, an operator who *removes* an interface from the allowlist via push will not actually stop capture on it.

Two paths forward:
1. Document this as Phase 1's intentional scope: bootstrap allowlist is authoritative; runtime allowlist changes require sidecar restart. Then `RuntimeConfig::apply` should *reject* a config whose `capture_interfaces` differs from the bootstrap set, so the agent surfaces the conflict instead of silently no-op'ing.
2. Implement live re-open of capture handles in `apply()`. Larger scope, but matches the spec scenario more cleanly.

Recommend option 1 for Phase 1; bump option 2 to a future task.

---

### Minor

#### Mi-1. `IpcServer::prepare_socket` uses default umask
**File:** `rust/netprobe/src/server.rs:83-95`
**Spec mapping:** `agent-sidecar-runtime` — `Per-sidecar Unix domain socket lifecycle` (mode `0700`).

`std::fs::create_dir_all(parent)` honours the process umask (typically `0022`, yielding `0755`). The spec puts the directory-creation duty on the agent's sidecar manager, not the sidecar, but defense-in-depth is cheap: after `create_dir_all`, `chmod 0700` the parent dir, and after `bind` `chmod 0660` (or `0600`) the socket itself. Two `nix::sys::stat::fchmod*` calls. Prevents an accidentally-permissive systemd `RuntimeDirectoryMode` or `RuntimeDirectory` not being declared at all from leaving the IPC socket world-readable.

#### Mi-2. `active_client` lock leaks on `handle_client` panic
**File:** `rust/netprobe/src/server.rs:67-77`

```rust
tokio::spawn(async move {
    let result = handle_client(stream, event_rx, runtime_config).await;
    active_client.store(false, Ordering::SeqCst);
    if let Err(err) = result {
        log::warn!(...);
    }
});
```

If `handle_client` panics (any `expect()`/`unwrap()` deep in the call graph), the `tokio::spawn` future aborts before the `active_client.store(false)` line ever runs. Subsequent agent connection attempts get rejected forever until the sidecar is restarted. Either:
- wrap the work in `std::panic::AssertUnwindSafe`/`futures::FutureExt::catch_unwind`, **or**
- move the `store(false)` into a `struct GuardActiveClient(Arc<AtomicBool>)` whose `Drop` resets it (RAII pattern). This survives panics because `Drop` runs during unwinding.

#### Mi-3. Lagged broadcast events emit no metric
**File:** `rust/netprobe/src/server.rs:134-136`

```rust
Err(broadcast::error::RecvError::Lagged(skipped)) => {
    log::warn!("netprobe IPC client lagged; skipped {skipped} fingerprint event(s)");
}
```

Logs are unstructured signal; a counter is structured signal. Add a `netprobe_ipc_events_lagged_total` (or extend `events_emitted_total` with a `dropped` label) so operators can spot slow clients via the metrics endpoint. The `agent-sidecar-runtime` spec asks for visibility into sidecar state; this is a small but concrete part of that.

#### Mi-4. `CAP_NET_RAW = 13` magic number
**File:** `rust/netprobe/src/capabilities.rs:21`

```rust
const CAP_NET_RAW: u64 = 13;
```

13 is correct (per `linux/capability.h`), but a reader has to know that. Either link the `caps` crate (`caps::CapsHashSet`, `caps::has_cap`) or at minimum add `// SAFETY: CAP_NET_RAW from <linux/capability.h>; see capabilities(7)`.

#### Mi-5. `snaplen(65535)` is larger than needed for headers-only fingerprinting
**File:** `rust/netprobe/src/capture.rs:218-222`

```rust
let capture = pcap::Capture::from_device(interface)?
    .promisc(false)
    .snaplen(65_535)
    ...
```

p0f-style fingerprinting only needs L2 + L3 + L4 headers + TCP options + (for HTTP) the first request/response line and a handful of headers. ~256–512 bytes is sufficient. 65535 wastes ring-buffer space, kernel-to-user copy bandwidth, and pcap parse time. Drop to a tunable default (e.g. 384).

#### Mi-6. Capture loop uses wall-clock now() instead of pcap packet timestamp
**File:** `rust/netprobe/src/capture.rs:160`

```rust
let events = engine.analyze_packet(&interface, now_unix_nano(), packet.data);
```

`packet.header.ts` is the kernel-stamped pcap timestamp for the captured frame. Using `now_unix_nano()` introduces drift = pcap ring delay + scheduling jitter + `Instant::now()` syscall cost. Material when downstream correlates `observed_at_unix_nano` against NetFlow records in Phase 4. Cheap to fix now.

#### Mi-7. `bindings_by_ip` silently overwrites duplicate IPs
**File:** `rust/netprobe/src/runtime_config.rs:156-174`

If the agent ever delivers two `DeviceBinding` entries with the same `ip`, the second wins silently. Per the `VisibilityCompiler` design the compiler will already de-duplicate by IP, but the sidecar should `log::warn!` (or count a metric) when it sees duplicates so misbehaving compilers are observable in the wild.

#### Mi-8. `bindings_by_ip` defaults missing fingerprint config to all-on
**File:** `rust/netprobe/src/runtime_config.rs:168`

```rust
fingerprint: binding.fingerprint.clone().unwrap_or_else(all_fingerprints_enabled),
```

The spec says each analyser is "independently toggleable from the agent-delivered configuration". An operator who omits `fingerprint` (intentionally, as a misconfiguration, or because the compiler dropped it) gets all three protocols turned on. Safer default: omitted `fingerprint` = all-off (== "no events for this device until you opt in"). Operators expect missing config to be conservative.

#### Mi-9. Shutdown awaits tasks sequentially
**File:** `rust/netprobe/src/main.rs:117-124`

```rust
let metrics_result = metrics_task.await...;
metrics_result.context(...)?;
let ipc_result = ipc_task.await...;
ipc_result.context(...)?;
```

If `metrics_task` is slow to drain, the 5-second budget is consumed before `ipc_task` even starts to be awaited. Use `tokio::try_join!(metrics_task, ipc_task)` so both drain in parallel.

#### Mi-10. Orphan `etherparse` dep
**File:** `rust/netprobe/Cargo.toml:17`

`etherparse = "0.20.1"` is declared but no `use etherparse` exists in `src/`. Either remove it or move to a Phase-3 dependency island with a comment explaining when it'll be wired.

#### Mi-11. Static-link CI does not assert binary runs
**File:** `.forgejo/workflows/tests-rust.yml:264-305`

The matrix verifies the musl binary is statically linked (`file`/`readelf`), but never executes it (not even `--help`). Combined with B-1, the only way the next CI run could catch a regression in the binary's startup path is by accident. Add `bazel run` of the binary with `--help` (or a `--check-config` mode) so symbol-resolution failures, missing capabilities, etc., are caught.

---

### Nits

#### N-1. Capture workers always start, even when `config.enabled = false`
**File:** `rust/netprobe/src/main.rs:78-104`

When the bootstrap config disables the sidecar, `initialize_privileged_resources` still opens pcap and `CaptureWorkers::start` still spawns capture threads. The `RuntimeConfig` gate prevents emission, but CPU is still spent on packet parsing. Either short-circuit at startup or document the behaviour explicitly.

#### N-2. `should_emit` writes the bucket even when no rate limit applies
**File:** `rust/netprobe/src/runtime_config.rs:210-213`

```rust
if sample_interval_ms == 0 {
    last_emitted.insert((ip.to_string(), protocol), observed_at_unix_nano);
    return true;
}
```

The write is wasted work since the timestamp will never be inspected. Just `return true;`. Memory savings are negligible per call but the map grows unbounded over time even for "unlimited" devices.

#### N-3. `DefaultHasher` is not stable across Rust versions
**File:** `rust/netprobe/src/runtime_config.rs:227-231`

```rust
fn config_hash(config: &VisibilityAgentConfig) -> String {
    let mut hasher = DefaultHasher::new();
    config.encode_to_vec().hash(&mut hasher);
    format!("netprobe-v1:{:016x}", hasher.finish())
}
```

`SipHasher` is the current implementation but the stdlib makes no compatibility guarantee. If two binaries built against different toolchains compare config hashes (e.g. agent built nightly, sidecar built stable), they'll disagree. Use a stable hash (blake3, xxhash, or sha256-truncated). Since the `netprobe-v1:` prefix is already present, this is forward-compatible.

#### N-4. JSON log records have no timestamp
**File:** `rust/netprobe/src/main.rs:139-152`

Hand-rolled JSON omits `time`. The agent's log forwarder may inject a receive timestamp, but a sender-emitted timestamp is more useful for debugging clock skew. Either add `time` or use `tracing-subscriber` for richer structured output (note this is a larger change).

#### N-5. Two parallel allowlist-validation surfaces
**File:** `rust/netprobe/src/config.rs:34-75`

`Config::validate_capture_interfaces` and `validate_interface` overlap; only the first is in the live path. The second exists for future "validate a single requested interface" use cases but is `#[allow(dead_code)]`. Either delete and re-add later, or call it from `capture::open_allowlisted_interfaces` so the dead-code allow can go away.

---

### Spec-vs-implementation tracking (gaps, not bugs)

These are spec requirements that are **not yet implemented** per the `tasks.md` checklist. Listed so the live document tracks the surface area that still needs review when those tasks get checked off.

| ID | Task | Spec | Status |
|----|------|------|--------|
| T-1 | §3.2 TLS JA4S extraction | `host-network-visibility` — `huginn-net signature engine integration` (TLS analyser) | `TlsFingerprint.ja4s` emitted as empty string at `fingerprint.rs:267`. Untested. |
| T-2 | §3.6 pcap-fixture unit tests | (test-only) | One IPv4 SYN fixture test exists at `fingerprint.rs:287-301`. No HTTP or TLS fixture tests. |
| T-3 | §3.7 end-to-end integration test | (test-only) | `server.rs::tests` are unit tests of the IPC layer only. No `#[tokio::test]` that drives `CaptureWorkers` + huginn-net against a real pcap blob. |
| T-4 | §4.2 `buf` lint pass | (build infra) | No `buf.yaml` / `buf.gen.yaml` workflow step found for `proto/agent/netprobe/v1/`. |

### Process / spec hygiene observations

- **`tasks.md` §4.3 path mismatch.** Task description says "Generate Go bindings under `go/proto/agent/netprobe/v1/`"; implementation places them at `proto/agent/netprobe/v1/netprobe.pb.go` — which matches the existing repo convention (`proto/discovery/`, `proto/monitoring.pb.go`, etc.). The task description is the thing to fix; the implementation is right.

---

---

## Pass 2 — 2026-05-27

**Coverage:** commits `3e10881..7577641` (10 commits). Covers tasks §3.2 (TLS JA4 only — JA4S still pending), §5 (sidecar runtime, all 9 done), §6 (Go bridge, all 5 done), §7 (agent config delivery, all 5 done), §9.1 (`passive-netprobe` discovery source enum).

**New files reviewed:**
- `rust/netprobe/src/fingerprint.rs` — TLS JA4 wiring delta only
- `go/pkg/agent/sidecar/{types,manager,manager_test,process_unix,process_windows,status_proto,status_proto_test}.go` + `README.md` + `BUILD.bazel`
- `go/pkg/agent/netprobe/{client,client_test,framing,framing_test,sidecar,sidecar_test,translator,translator_test,config,config_test}.go` + `BUILD.bazel`
- `proto/monitoring.proto` deltas (SidecarStatus, VisibilityConfig family)
- `go/pkg/models/discovery.go` — `DiscoverySourcePassiveNetprobe`
- `elixir/serviceradar_core/lib/serviceradar/edge/agent_config_generator.ex` — `load_visibility_config` + proto builders + version-hash inclusion
- `elixir/serviceradar_core/test/serviceradar/edge/{agent_config_visibility_proto_test,agent_config_generator_test}.exs` — visibility test additions
- `elixir/serviceradar_agent_gateway/test/serviceradar_agent_gateway/stream_config_limits_test.exs` — 5k-binding chunking case

**Verdict:** The Go-side foundation is well-engineered: clean separation between the generic supervisor and the netprobe-specific bridge, comprehensive test coverage of framing/backpressure/Ping/ApplyConfig/error paths, and a properly threaded `cmd.Cancel`/`cmd.WaitDelay` graceful-shutdown pattern. The Elixir generator integration is idiomatic and gracefully degrades when the `:visibility` compiler isn't registered yet (Phase 1 reality).

Three structural concerns hold this back from "ship-ready":
1. **Sidecar runtime spec deviations.** Socket directory layout and permissions don't match `agent-sidecar-runtime`'s `Per-sidecar Unix domain socket lifecycle` requirement. Easy to fix; spec language is unambiguous.
2. **`client.go` close race.** The events channel is closed from `closeWithError` while `readLoop` may still be mid-send. Standard "sender owns close" violation; rare panic possible.
3. **No production wiring for `ApplyConfig`.** The Sidecar's `OnHealthy` callback receives a short-lived health-probe client that the manager closes immediately. There is no long-lived netprobe client maintained for `ApplyConfig` / `DrainFingerprintEvents` — so the spec requirements `Profile change invalidates the config hash` (agent-config) and `Visibility sub-config refresh on push-config delivery` (agent-configuration) cannot be satisfied yet. The proto field exists end-to-end; the runtime push doesn't.

**Pass 1 status update (no movement):** Every Pass 1 finding remains open. The two blockers (B-1 musl pcap-capture stripped, B-2 no cargo test for netprobe in CI) are unchanged. Pass 1 majors M-1 through M-4 are unchanged. All Pass 1 minors and nits are unchanged.

### Severity summary (this pass only)
| | Pass 2 |
|---|---|
| Blocker | 0 |
| Major | **5** |
| Minor | **12** |
| Nit | **5** |
| Tracking | 2 |

### Running totals across all passes
| | Open |
|---|---|
| Blocker | 2 (both from Pass 1) |
| Major | 9 (4 from Pass 1, 5 new) |
| Minor | 23 (11 from Pass 1, 12 new) |
| Nit | 10 (5 from Pass 1, 5 new) |
| Tracking | 6 (4 from Pass 1, 2 new) |

---

### Pass 2 — Major

#### M-5. Sidecar socket directory layout doesn't match spec
**Files:** `go/pkg/agent/sidecar/manager.go:37, 135-140, 499-504`
**Spec mapping:** `agent-sidecar-runtime` — `Per-sidecar Unix domain socket lifecycle`.

Spec language: *"The manager SHALL create a per-sidecar socket directory under `/run/serviceradar/<name>/` with `0700` permissions, pass the socket path to the sidecar via `--socket`, and reuse the same socket for the sidecar's lifetime."*

Implementation gives a single shared directory with per-sidecar socket files:

```go
defaultRuntimeDir   = "/run/serviceradar/sidecars"
...
if err := os.MkdirAll(m.cfg.RuntimeDir, 0o750); err != nil { ... }
...
func socketPath(runtimeDir, name string) string {
    return filepath.Join(runtimeDir, name+".sock")  // /run/serviceradar/sidecars/netprobe.sock
}
```

Two deviations:
1. **Path:** spec wants `/run/serviceradar/<name>/`, impl gives `/run/serviceradar/sidecars/`. With multiple sidecars in the future the sockets co-mingle in one directory whose contents reveal the sidecar inventory.
2. **Mode:** spec wants `0700`, impl uses `0o750`. The extra group bit means any user in the agent's primary group can `connect()` to the IPC socket, which (in Phase 5 when remote-capture lands) means anyone in that group can hijack the netprobe IPC channel — including triggering pcapng capture sessions.

Fix: change `defaultRuntimeDir` to `/run/serviceradar`, update `socketPath` to `filepath.Join(runtimeDir, name, "ipc.sock")` (or similar per-sidecar subdir), `MkdirAll` the per-sidecar dir with `0o700`, and (defense-in-depth) `chmod 0o600` the socket itself after `bind`.

#### M-6. Extra sidecar states `Healthy` and `Failed` not enumerated in spec
**File:** `go/pkg/agent/sidecar/types.go:42-54`
**Spec mapping:** `agent-sidecar-runtime` — `Sidecar state surfaced in agent status`.

Spec scenario: *"the entry reports `name`, `state` (one of `starting`, `running`, `unhealthy`, `restarting`, `circuit_open`, `stopped`)"*.

Implementation defines 8 states; the two extras are `StateHealthy` and `StateFailed`. `Healthy` is used after every successful probe (overwriting `Running`); `Failed` is declared but never assigned anywhere in `manager.go`. Two consequences:

1. Downstream consumers (web-ng Agent Detail page, SRQL queries on `state`) will see `healthy` for steady-state — not in the spec's enum — and `running` only briefly between Start and the first successful probe.
2. The unused `StateFailed` is dead code today; either remove it or assign it (e.g. when `circuit_open` permanently locks out).

Either expand the spec's enum (cheap proposal amendment) or collapse `Healthy` into `Running` and remove `Failed`. Recommend the latter — `running` already implies "exists and not unhealthy"; adding `Healthy` doesn't add information.

#### M-7. `netprobe.Client` `readLoop` can panic on close race
**Files:** `go/pkg/agent/netprobe/client.go:268-298, 316-334`

```go
func (c *Client) readLoop() {
    for {
        frame, err := readFrame(c.conn)
        if err != nil {
            // ... close path
        }
        if frame.GetSequence() == 0 {
            if event := frame.GetFingerprintEvent(); event != nil {
                select {
                case c.events <- event:        // ← can panic if events is already closed
                default:
                    c.recordEventDrop(...)
                }
            }
            continue
        }
        // ...
    }
}

func (c *Client) closeWithError(err error) {
    c.closeOnce.Do(func() {
        // ...
        _ = c.conn.Close()
        c.pendingMu.Lock()
        for sequence, ch := range c.pending {
            delete(c.pending, sequence)
            ch <- response{err: err}
        }
        c.pendingMu.Unlock()
        close(c.events)                       // ← closes channel still being sent on
        close(c.done)
    })
}
```

Race: a caller invokes `Close()` while `readLoop` is between `readFrame` returning a frame and the `select { case c.events <- event: ... }` line. The `closeWithError` proceeds to `close(c.events)`. Then `readLoop` runs its `case c.events <- event:` send — send on closed channel — panic.

Window is small (microseconds) but live. The standard fix is "sender owns close": move `close(c.events)` out of `closeWithError` and into a defer inside `readLoop`, e.g.:

```go
func (c *Client) readLoop() {
    defer close(c.events)
    for {
        // ... existing logic, with the conn.Close() in closeWithError causing
        // readFrame to fail and the loop to exit naturally
    }
}
```

`closeWithError` then only closes the conn + drains pending + closes `done`. `readLoop` notices the conn closing on its next read, exits the loop, and the deferred `close(c.events)` runs.

#### M-8. No production wiring for `ApplyConfig` / event drain
**Files:** `go/pkg/agent/netprobe/sidecar.go:98-114`, `go/pkg/agent/sidecar/manager.go:320-347`
**Spec mapping:** `agent-config` — `Visibility sub-config compilation and delivery` (scenario "Profile change invalidates the config hash"); `agent-configuration` — `Visibility sub-config refresh on push-config delivery`.

The sidecar manager opens one IPC connection per health probe (every 5 s), calls `Ping`, invokes `OnHealthy(client)`, then immediately `client.Close()`s:

```go
// manager.go:325-340
if err == nil {
    *failures = 0
    m.setHealthy(sc.Name(), pid)
    sc.OnHealthy(client)
    if closeErr := client.Close(); closeErr != nil { ... }
    return
}
```

The netprobe Sidecar's `OnHealthy` only stashes the engine version:

```go
// sidecar.go:98-106
func (s *Sidecar) OnHealthy(client sidecar.Client) {
    s.healthy.Store(true)
    s.unhealthy.Store(false)
    s.lastError.Store("")
    if netprobeClient, ok := client.(*Client); ok {
        s.engineVersion.Store(netprobeClient.FingerprintEngineVersion())
    }
}
```

Nothing in this package — or anywhere else in the repo I can grep — establishes a **long-lived** netprobe `Client` to call `ApplyConfig(...)` when a new `VisibilityConfig` arrives from `AgentConfigResponse`, or to drain `Events()` into the discovery pipeline. The `DrainFingerprintEvents` helper has no caller.

The spec requires the agent to "re-apply the new visibility bindings to the supervised sidecar via its IPC `ApplyConfig` call before acknowledging any push-config delivery whose `visibility_config` differs from the currently-applied configuration". With only ephemeral health clients, this is impossible.

Phase 1 §5/§6 tasks are checked off, but the system-level integration that the spec requires lives somewhere downstream (likely the agent's main control-stream handler, not in this package). Either:
1. Wire a long-lived `*netprobe.Client` in the agent's startup path (probably `cmd/agent/main.go` or `pkg/agent/server.go`), or
2. Extend `sidecar.Manager` (or the netprobe `Sidecar`) to own a persistent client alongside the probe loop, exposing `ApplyConfig(ctx, cfg)` and `Events()` on the Sidecar.

Option 2 is closer to the current packaging boundaries and feels right architecturally. Either way, the spec scenarios cannot pass until this lands.

#### M-9. Repeated `OnUnhealthy` emission once threshold crosses
**File:** `go/pkg/agent/sidecar/manager.go:342-346`

```go
*failures++
if *failures >= m.cfg.UnhealthyThreshold {
    m.setUnhealthy(sc.Name(), pid, err)
    sc.OnUnhealthy(err)
}
```

Once `*failures == 3`, the next failed probe makes it `4`, `5`, … and the `>=` check keeps firing `OnUnhealthy` on every probe. Downstream observers (status surface, metrics, the netprobe Sidecar's `unhealthy` atomic) are repeatedly notified for the same unhealthy condition. Edge-trigger the callback:

```go
*failures++
if *failures == m.cfg.UnhealthyThreshold {
    m.setUnhealthy(sc.Name(), pid, err)
    sc.OnUnhealthy(err)
}
```

…and reset `*failures` to 0 on success (already done) and on process exit (currently dropped on the floor when `runOnce` returns).

---

### Pass 2 — Minor

#### Mi-12. Backoff never resets after a long successful run
**File:** `go/pkg/agent/sidecar/manager.go:202, 237-240`

```go
func (m *Manager) supervise(ctx context.Context, sc Sidecar) {
    defer m.wg.Done()

    backoff := m.cfg.RestartBackoffInitial
    // ...
    for {
        // ... runOnce, etc.
        backoff *= 2
        if backoff > m.cfg.RestartBackoffMax { backoff = m.cfg.RestartBackoffMax }
    }
}
```

If a sidecar crashes 5 times in a minute (backoff doubles to ~16 s), then runs successfully for a week, the next crash uses the old `16 s` back-off. Reset the back-off when a successful run exceeds some duration threshold (e.g. the back-off cap itself, or 30 s):

```go
runStart := time.Now()
err := m.runOnce(ctx, sc)
if time.Since(runStart) > m.cfg.RestartBackoffMax {
    backoff = m.cfg.RestartBackoffInitial
}
```

#### Mi-13. Sidecar stderr defaults to ERROR log level
**File:** `go/pkg/agent/sidecar/manager.go:454-460`

```go
for scanner.Scan() {
    line := scanner.Text()
    if isErr {
        log.Error().Str("stream", "stderr").Msg(line)
    } else {
        log.Info().Str("stream", "stdout").Msg(line)
    }
}
```

`env_logger` (which netprobe uses) writes Info-level messages to stderr. After the manager forwards them they appear at Error level in the agent's logs, swamping the agent's structured log output with false errors. Two options:
1. For `json` log format (which netprobe supports), parse the line and extract the embedded level.
2. For both formats, default stderr to `Warn` rather than `Error`, and let the sidecar binary use stdout for non-error output. (Requires a netprobe-side change too: currently `env_logger` defaults to stderr regardless of level.)

#### Mi-14. `last_health_at` is Unix seconds, inconsistent with nanosecond timestamps elsewhere
**Files:** `proto/monitoring.proto:84`, `go/pkg/agent/sidecar/status_proto.go:29-32`

Most of the netprobe stack uses `int64` Unix nanoseconds (`observed_at_unix_nano`, `sent_at_unix_nano`, `acked_at_unix_nano`). `SidecarStatus.last_health_at` is `int64` Unix seconds, losing sub-second resolution. For a 5-second probe interval the loss is mostly cosmetic, but a JSON UI that interleaves `last_health_at` with other observation timestamps will display jumpy seconds-only fields next to ns-precision ones. Either align to nanos here, or document the intentional truncation.

#### Mi-15. Translator passes TLS SNI through verbatim without re-redacting
**File:** `go/pkg/agent/netprobe/translator.go:147`

```go
metadata[metadataPassiveFingerprintBase+".tls.sni_redacted"] = strings.TrimSpace(tls.GetSniRedacted())
```

The Rust side enforces SNI redaction at the IPC boundary (only emits `"<present>"` or `""`). But the test fixture `translator_test.go:105` happily passes a literal hostname (`"example.invalid"`) and asserts it flows through verbatim into metadata. If a future regression on the sidecar side (deliberate or accidental) ever produced a real SNI value, the translator would silently propagate it to inventory metadata. Defense in depth: have the translator assert the value is one of `{"", "<present>"}` (or hash anything else), so a sidecar regression fails closed.

#### Mi-16. First health probe ignores `ctx` cancellation
**File:** `go/pkg/agent/sidecar/manager.go:303-318`

```go
func (m *Manager) healthLoop(ctx context.Context, sc Sidecar, socketPath string, pid int) {
    ticker := time.NewTicker(m.cfg.HealthInterval)
    defer ticker.Stop()

    failures := 0
    m.probeHealth(ctx, sc, socketPath, pid, &failures)  // ← runs even if ctx is already canceled

    for {
        select {
        case <-ctx.Done(): return
        case <-ticker.C:    m.probeHealth(ctx, sc, socketPath, pid, &failures)
        }
    }
}
```

Wrap the first probe in a check:

```go
if ctx.Err() == nil {
    m.probeHealth(ctx, sc, socketPath, pid, &failures)
}
```

#### Mi-17. `uint16String` reimplements `strconv.FormatUint`
**File:** `go/pkg/agent/netprobe/sidecar.go:130-144`

`strconv.FormatUint(uint64(value), 10)` is the canonical pattern. The hand-rolled byte-buffer version avoids importing `strconv` for nothing; the package already has many other strconv-free formatters, but inconsistency is the only argument either way. Trivial.

#### Mi-18. Visibility hash inclusion forces one-time config churn for all agents
**File:** `elixir/serviceradar_core/lib/serviceradar/edge/agent_config_generator.ex:913-924`

The version hash now includes `visibility: stable_config_fragment(visibility_config)`. On first deploy with this change, every agent's previously-cached version hash will mismatch, forcing a full config re-fetch on the next poll. Not a correctness bug — just a release-coordination note. Worth adding to the changelog so operators don't misread the resulting traffic spike.

#### Mi-19. `compactStrings` drops empty entries before validation
**File:** `go/pkg/agent/netprobe/config.go:87-101`

The Go parser silently trims empty interface names from the allowlist before the sidecar gets to validate. If an operator misconfigures with `["en0", "", "any"]`, the sidecar receives `["en0", "any"]` and properly rejects on `"any"`. But the empty entry is silently absorbed without logging — operators may not see a clue that their config carried garbage. Add a `slog`/zerolog warn when a non-empty input set produces an empty output entry.

#### Mi-20. `ToProtoStatuses` casts `int` → `uint32` without overflow check
**File:** `go/pkg/agent/sidecar/status_proto.go:39`

```go
RestartCount: uint32(status.RestartCount),
```

Realistically unreachable (4 billion restarts), but pure code hygiene: cap at `math.MaxUint32` or change `Status.RestartCount` to `uint32` upstream.

#### Mi-21. `confidence` formatting uses float32 minimum-precision
**File:** `go/pkg/agent/netprobe/translator.go:141`

```go
metadata[metadataPassiveFingerprintBase+".tcp.confidence"] = strconv.FormatFloat(float64(tcp.GetConfidence()), 'f', -1, 32)
```

`-1` precision means "shortest representation that round-trips through float32". For some values that produces clean strings like `"0.92"` (which the test happens to assert); for others (e.g. `0.7`) you'll get `"0.69999999"`. Pin precision to 3 decimals (`'f', 3, 32`) for consistent metadata across downstream consumers.

#### Mi-22. Capture metrics endpoint binds before privileges drop
**File:** `rust/netprobe/src/main.rs:91-112` (pre-existing — covered indirectly by Pass 1 but worth flagging)

`metrics_task` is spawned via `tokio::spawn` which then calls `serve_metrics` which calls `TcpListener::bind(127.0.0.1:9417)`. The bind happens after `initialize_privileged_resources` has dropped privileges (good), but on `127.0.0.1` only (good — localhost-scoped). No finding here; reaffirming the Pass 1 expectation that the localhost-only binding is the right posture.

#### Mi-23. Manager tests rely on shell scripts; no Windows coverage
**File:** `go/pkg/agent/sidecar/manager_test.go:33, 81, 124`

Each table skips on Windows. The Windows-specific `signalTerminate` (uses `process.Kill()`) has no test coverage. Phase 1 ships Linux-only so this is acceptable, but the spec talks about cross-platform sidecars; eventually we want an integration test that pipes the SIGTERM-equivalent on Windows.

---

### Pass 2 — Nits

#### N-6. Tight test backoff defaults can be flaky on overloaded runners
**File:** `go/pkg/agent/sidecar/manager_test.go:168-171`

```go
HealthInterval:        10 * time.Millisecond,
ShutdownGrace:         250 * time.Millisecond,
RestartBackoffInitial: time.Millisecond,
RestartBackoffMax:     5 * time.Millisecond,
```

Tight enough that a 50 ms scheduler hiccup on a loaded laptop could affect `RestartCount` expectations. Move to ~50 ms / 1 s / 10 ms / 100 ms ranges to give CI more headroom.

#### N-7. `cmd.Cancel` returning `os.ErrProcessDone` is not idiomatic
**File:** `go/pkg/agent/sidecar/manager.go:253-258`

The Go 1.20 `cmd.Cancel` docs say to return errors that influence what `Wait()` returns. Returning `os.ErrProcessDone` is unusual; the standard pattern is to return `nil` when the cancel was a no-op, or the OS error from the signal attempt. Cosmetic.

#### N-8. Repeated `Args` allocation per probe
**File:** `go/pkg/agent/sidecar/types.go:37`

`Args(socketPath, configPath string) []string` is called once per child restart (not per probe), so the per-call alloc is fine — flagging only because the receiver was sometimes called per-probe in earlier drafts.

#### N-9. `Compiler.compiler_for(:visibility)` lookup on every config request
**File:** `elixir/serviceradar_core/lib/serviceradar/edge/agent_config_generator.ex:1215-1217`

```elixir
defp load_visibility_config(agent_id) do
    case Compiler.compiler_for(:visibility) do
      {:ok, _compiler} -> ...
      {:error, :unknown_config_type} -> disabled_visibility_config()
    end
end
```

Per-request lookup is fine — Compiler.compiler_for is presumably a registry lookup, not a heavy operation. Just calling out for posterity.

#### N-10. `log scanner` buffer fixed at 1 MiB
**File:** `go/pkg/agent/sidecar/manager.go:45, 452`

```go
sidecarLogScannerMaxBufferSize = 1024 * 1024
```

A pathological long log line (e.g. a panic traceback) > 1 MiB will be truncated. Operators tracking down a sidecar panic could lose information. Likely overkill to fix but worth noting.

---

### Pass 2 — Spec-vs-implementation tracking (gaps, not bugs)

| ID | Task | Spec | Status |
|----|------|------|--------|
| T-5 | §3.2 TLS JA4S (server) extraction | `host-network-visibility` — TLS analyzer | JA4 (client) now wired (`fingerprint.rs:266`); JA4S still emitted as empty string at `fingerprint.rs:267`. Task remains unchecked. |
| T-6 | §8 Ash control plane (VisibilityProfile + compiler) | `host-network-visibility` — `Unified visibility profile model`, `Per-device binding compilation` | Not started. The `agent_config_generator.ex:1215` gracefully handles missing `:visibility` compiler — the Phase 1 system can run end-to-end *without* §8, returning `disabled_visibility_config()`. Once §8 lands, this code path activates. |
| T-1 → T-4 from Pass 1 | (carried) | (carried) | Unchanged — see Pass 1. |

### Process / spec hygiene observations (Pass 2)

- **Test fixture privacy regression risk.** `translator_test.go:105` uses `SniRedacted: "example.invalid"` (a literal hostname) and asserts it flows through to metadata. The Rust sidecar's actual contract emits `"<present>"` or `""` only. The test passes a value the sidecar will never emit; a future contributor reading the test might think hostnames are allowed in `SniRedacted` and remove the Rust-side redaction by mistake. Recommend the test use `"<present>"` to mirror real behaviour, and add a separate assertion that anything else is rejected/sanitised (see Mi-15).
- **`stream_config_limits_test.exs` 5k binding case is excellent.** Directly satisfies §7.4 ("add a streaming test case with 5,000 device bindings"). Good to see the chunking budget verified at protobuf level rather than at JSON.

---

---

## Pass 3 — 2026-05-27

**Coverage:** commits `ee55c050e..c7ae29e0b` (15 commits). Closes tasks §3.6, §3.7, §5.1 (Bazel test target), and most of §8 (Ash control plane), §9 (discovery ingestion), §10 (identity reconciliation), §11 (RBAC + capability surfacing), §12 (Web UI), §13 (packaging), §14 (docs), §15 (validation — partial). Still pending: §3.2 JA4S, §4.2/4.3 (buf lint + proto-binding path tidy), §8.2 (Ash codegen migration), §9.4, §12.7, §13.6, §15.4/15.5.

**New files reviewed (priority):**
- `elixir/serviceradar_core/lib/serviceradar/inventory/visibility_profile.ex` (190 lines, new)
- `elixir/serviceradar_core/priv/repo/migrations/20260527123000_create_visibility_profiles.exs` (76 lines, new)
- `elixir/serviceradar_core/lib/serviceradar/agent_config/compilers/visibility_compiler.ex` (181 lines, new)
- `elixir/serviceradar_core/lib/serviceradar/inventory/passive_fingerprint_payload.ex` (190 lines, new)
- `elixir/serviceradar_core/lib/serviceradar/inventory/identity_reconciler.ex` (1860 lines; +95 new for passive-fingerprint signal)
- `elixir/serviceradar_core/lib/serviceradar/inventory/device_identifier.ex` (+15 line delta)
- `elixir/serviceradar_core/lib/serviceradar/inventory/device_enrichment_rules.ex` (+98 line delta)
- `elixir/serviceradar_core/lib/serviceradar/inventory/sync_ingestor.ex` (delta)
- `elixir/serviceradar_core/priv/device_enrichment/rules/visibility_enrichment_rules.yaml` (75 lines, new)
- `elixir/serviceradar_core/lib/serviceradar/identity/rbac/catalog.ex` (+18 line delta)
- `elixir/serviceradar_core/lib/serviceradar/edge/agent_gateway_sync.ex` (delta — capability → discovery-source mapping)
- `elixir/serviceradar_core/lib/serviceradar/registry/agent_registry.ex` (delta — `normalize_capability`)
- `go/pkg/agent/push_loop.go` (+88 line delta — capability advertising)
- `go/pkg/agent/server.go`, `types.go` (small deltas)
- `build/packaging/agent/scripts/postinstall.sh` (full file — setcap script)
- `build/packaging/agent/BUILD.bazel`, `packages.bzl`, `docker/images/BUILD.bazel`, `helm/serviceradar/values.yaml` (packaging diffs)
- `rust/netprobe/BUILD.bazel` (+ `rust_test` target — addresses Pass 1 B-2)
- `elixir/web-ng/lib/serviceradar_web_ng_web/router.ex` (+3 lines)
- `elixir/web-ng/lib/serviceradar_web_ng_web/live/settings/visibility_profiles_live/index.ex` (1122 lines, skim only)
- `elixir/web-ng/lib/serviceradar_web_ng_web/live/agent_live/show.ex` (+163 lines delta — Network Visibility card)
- `elixir/web-ng/lib/serviceradar_web_ng_web/live/device_live/show.ex` (+120 lines delta — Passive Fingerprint panel)

**Not reviewed in this pass (out-of-scope for Phase 1 review or low-value):** Cargo.lock, `MODULE.bazel.lock`, generated `*.pb.go` files, runbook `docs/docs/netprobe.md` (171 lines, content-only), all `*_test.exs` test fixtures (saw the suite list, not every assertion).

**Verdict:** This pass effectively closes the Phase 1 implementation surface end-to-end. The Ash + LiveView work is well-structured, RBAC is wired correctly, the migration creates a clean table with check constraints, the sanitizer normalizes mixed-format inbound metadata, and the identity reconciler correctly registers passive fingerprints with `confidence: :weak` and excludes them from merge logic. Two important resolutions from prior passes: **Pass 1 B-2 (no CI test coverage) is RESOLVED** by adding a `rust_test` Bazel target; **tracking items T-2 and T-3 (pcap fixtures + IPC integration test) are RESOLVED** by the dedicated test commits.

Three new structural issues stand out:
1. **The shipping binary is not musl-static.** The packaging targets reference `//rust/netprobe:netprobe` without selecting the musl platform, so deb/rpm/OCI ship the *glibc, dynamically-linked* build. The musl static build is exercised only in CI. This contradicts the `host-network-visibility` spec requirement *"MUST be statically linked against musl ... MUST NOT require any runtime shared-library dependencies"*.
2. **The Ash migration was hand-rolled with Ecto, not generated via `mix ash.codegen`** as the project's CLAUDE.md mandates ("All migrations through Ash — NEVER use `mix ecto.migrate` or `mix ecto.gen.migration`"). The hand-written migration parallels what codegen would emit but isn't tracked by Ash's migration metadata, which the workflow depends on.
3. **Capability advertising is hardcoded `enabled`/`unavailable`**, with no runtime check against sidecar state, kernel support, or the `netprobe.enabled` Helm value. An agent without the sidecar present, or with the sidecar in `circuit_open`, still announces `host-network-visibility.fingerprint.enabled` over the wire.

### Severity summary (this pass only)
| | Pass 3 |
|---|---|
| Blocker | 0 |
| Major | **5** |
| Minor | **9** |
| Nit | **5** |
| Tracking | 4 new, 2 resolved |

### Running totals across all passes
| | Open |
|---|---|
| Blocker | 1 (B-1 still open; B-2 RESOLVED in Pass 3) |
| Major | 14 (4 Pass 1, 5 Pass 2, 5 Pass 3) |
| Minor | 32 (11 Pass 1, 12 Pass 2, 9 Pass 3) |
| Nit | 15 (5 Pass 1, 5 Pass 2, 5 Pass 3) |
| Tracking | 8 open (4 Pass 1 → 2 open + 2 resolved; 2 Pass 2 open; 4 new Pass 3) |

---

### Pass 3 resolves prior findings

- **Pass 1 B-2 — RESOLVED.** Commit `51d21ca7a` adds a `rust_test` Bazel target at `rust/netprobe/BUILD.bazel:55-64`. Combined with task `15.1` checked off, all netprobe unit tests now run under `bazel test //rust/netprobe/...`.
- **Pass 1 T-2 — RESOLVED.** Commit `0cf588e09` adds pcap fixture coverage in `rust/netprobe/src/fingerprint.rs` (+209 lines).
- **Pass 1 T-3 — RESOLVED.** Commit `c7ae29e0b` adds an IPC integration test in `rust/netprobe/src/server.rs` (+135 lines).

All other Pass 1 and Pass 2 findings remain open.

---

### Pass 3 — Major

#### M-10. Passive fingerprint identifier hash is collision-prone
**File:** `elixir/serviceradar_core/lib/serviceradar/inventory/identity_reconciler.ex:167-197`

```elixir
defp passive_fingerprint_identifier(metadata) when is_map(metadata) do
  tokens =
    [
      passive_value(metadata, "tcp", "p0f_signature"),
      passive_value(metadata, "tcp", "signature"),
      passive_value(metadata, "tcp", "os_family"),
      passive_value(metadata, "tcp", "os_name"),
      passive_value(metadata, "tls", "ja4"),
      passive_value(metadata, "tls", "ja4s"),
      passive_value(metadata, "http", "server"),
      passive_value(metadata, "http", "user_agent")
    ]
    |> Enum.map(&normalize_passive_token/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()

  case tokens do
    [] ->
      nil
    tokens ->
      digest =
        tokens
        |> Enum.sort()
        |> Enum.join("|")
        |> then(&:crypto.hash(:sha256, &1))
        ...
```

The tokens are stripped of their field context before sorting + joining. Two devices with *swapped* field values produce identical hashes:

- Device A: `tls.ja4 = "X"`, `http.server = "Y"` → tokens `["X", "Y"]` → sorted `["X", "Y"]` → hash `H`
- Device B: `tls.ja4 = "Y"`, `http.server = "X"` → tokens `["Y", "X"]` → sorted `["X", "Y"]` → hash `H`

Both upsert to the same `DeviceIdentifier` row, overwriting each other's `device_id`. The current `lookup_by_strong_identifiers` excludes `passive_fingerprint` from the priority list (verified at L49), so this *cannot* cause spurious merges *today* — but the moment a future phase decides to consult passive-fingerprint rows for any decision (Phase 2 DPI? Phase 4 NetFlow attribution?), this collision becomes a real identity bug.

Prefix each token with its field name before sorting:

```elixir
tokens =
  [
    {"tcp.p0f_signature", passive_value(metadata, "tcp", "p0f_signature")},
    {"tcp.signature",     passive_value(metadata, "tcp", "signature")},
    ...
  ]
  |> Enum.map(fn {field, value} -> {field, normalize_passive_token(value)} end)
  |> Enum.reject(fn {_, value} -> is_nil(value) end)
  |> Enum.sort_by(fn {field, _} -> field end)
  |> Enum.map(fn {field, value} -> "#{field}=#{value}" end)
  |> Enum.join("|")
```

Without prefix, the hash is collision-prone by design.

#### M-11. Shipping binary is not musl-static — spec says it MUST be
**Files:** `build/packaging/agent/BUILD.bazel:14-24`, `build/packaging/packages.bzl:64-68`, `docker/images/BUILD.bazel:160`
**Spec mapping:** `host-network-visibility` — *"Bundled host visibility sidecar binary."* — "MUST be statically linked against musl for `x86_64-unknown-linux-musl` and `aarch64-unknown-linux-musl` and MUST NOT require any runtime shared-library dependencies."

All shipping artifacts reference `//rust/netprobe:netprobe` *without* a platform selection:

```starlark
pkg_files(
    name = "agent_release_runtime_files",
    srcs = [
        "//go/cmd/agent",
        "//rust/netprobe",        # ← default platform, NOT musl
    ],
    ...
)

PACKAGES = {
    "agent": {
        ...
        "binary": {
            "target": "//go/cmd/agent:agent",
            ...
        },
        "extras": [
            {
                "src": "//rust/netprobe:netprobe",  # ← default platform, NOT musl
                "dest": "/usr/local/lib/serviceradar/bin/serviceradar-netprobe",
                "mode": "0755",
            },
            ...
        ],
    },
    ...
}
```

The `select()` in `rust/netprobe/BUILD.bazel` only activates the musl no-pcap path when `--platforms=//build/platforms:linux_x86_64_musl` is passed. None of the agent's packaging targets pass that flag — they take the default platform (`linux_x86_64` glibc), which builds a glibc-linked, dynamically-loaded binary with `pcap-capture` enabled.

Net effect: the binary that ends up on customer hosts in deb/rpm/OCI is `dynamic, depends on libc, libpcap, libdl, libgcc_s, …`. Operators upgrading from glibc 2.34 → 2.39 (or running on Alpine, or anywhere libpcap is absent) will see startup failures.

Two paths to spec compliance:
1. Switch packaging to the musl platform — but then we revert to Pass 1 B-1 (no packet capture) until libpcap-musl-static is solved. Net regression.
2. Decide that the spec's "musl-static" requirement is aspirational for Phase 1, fix the spec, and document that the shipping binary is glibc-dynamic with explicit `libpcap` runtime requirement (already declared in `deb_depends`/`rpm_requires` indirectly via no entry — needs to be added). Either way the spec language and the implementation must agree.

Recommend option 2 plus a `host-network-visibility` spec amendment that says "dynamically-linked binary with libpcap runtime dependency on Linux ≥ glibc 2.34; static musl is a future goal" — and add `libpcap0.8` / `libpcap` to the deb/rpm `depends`. Currently neither is listed.

#### M-12. Capability advertising is hardcoded, ignores sidecar state and config
**File:** `go/pkg/agent/push_loop.go:67-94, 1929-1949, 3493-3500`

The agent unconditionally adds five capability strings to the advertisement:

```go
const (
    capabilityHostNetworkVisibility                    = "host-network-visibility"
    capabilityHostNetworkVisibilityFingerprintEnabled  = "host-network-visibility.fingerprint.enabled"
    capabilityHostNetworkVisibilityDPIUnavailable      = "host-network-visibility.dpi.unavailable"
    ...
)
...
func agentCapabilities(options agentCapabilityOptions) []string {
    capabilities := []string{
        ...,
        capabilityHostNetworkVisibility,
        capabilityHostNetworkVisibilityFingerprintEnabled,  // ← always emitted
        capabilityHostNetworkVisibilityDPIUnavailable,
        ...
    }
    ...
}
```

And in the capability status payload:

```go
func buildAgentCapabilityStatusResponse(capabilities []string, sidecars []*proto.SidecarStatus) *proto.StatusResponse {
    payload, _ := json.Marshal(agentCapabilityStatusPayload{
        Capabilities: append([]string(nil), capabilities...),
        HostNetworkVisibility: hostNetworkVisibilityCapabilityStatus{
            Fingerprint:     "enabled",         // ← hardcoded
            DPI:             "unavailable",
            FlowAttribution: "unavailable",
            ProcessSnapshot: "unavailable",
        },
        ...
    })
    ...
}
```

The status block does *not* consult `cfg.Netprobe.Enabled`, the sidecar runtime state (which it has via the `sidecarStatusProvider`), or even whether the binary exists. An agent on a macOS host (no musl Linux binary), or with `netprobe.enabled: false` in Helm, or with the sidecar in `circuit_open`, advertises `fingerprint = enabled` to the gateway.

**Downstream consequences:** The Elixir `agent_gateway_sync.ex:457-460` adds `passive-netprobe` to `discovery_sources` whenever the capability advertisement contains "host-network-visibility". So any agent that boots will have `passive-netprobe` registered as a discovery source on its device record, regardless of whether the sidecar can actually run.

Fix: derive the fingerprint state from `cfg.Netprobe.Enabled` AND the sidecar's actual state, e.g.:

```go
state := "unavailable"
if cfg != nil && cfg.Netprobe.Enabled {
    if hasHealthyNetprobe(sidecars) {
        state = "enabled"
    } else if hasDegradedNetprobe(sidecars) {
        state = "degraded"
    }
}
```

Same for the capability-list constants — only include `…fingerprint.enabled` when the state actually is `enabled`.

#### M-13. Migration was hand-written with Ecto; project mandates Ash codegen
**File:** `elixir/serviceradar_core/priv/repo/migrations/20260527123000_create_visibility_profiles.exs`
**Spec mapping:** project CLAUDE.md — *"All migrations through Ash - Use the Ash codegen workflow. NEVER use `mix ecto.migrate` or `mix ecto.gen.migration`."*

The migration is `use Ecto.Migration` with hand-rolled `create table(...)` and raw `execute` SQL for constraints:

```elixir
defmodule ServiceRadar.Repo.Migrations.CreateVisibilityProfiles do
  use Ecto.Migration

  def up do
    create table(:visibility_profiles, primary_key: false, prefix: "platform") do
      ...
    end
    ...
    execute("""
    ALTER TABLE platform.visibility_profiles
    ADD CONSTRAINT visibility_profiles_sample_interval_ms_check
    ...
    """)
  end
end
```

Task `8.2` ("Generate migration via `mix ash.codegen add_visibility_profile`") is checked **off** but the on-disk file is a hand-written Ecto migration, not Ash-generated. The Ash codegen workflow tracks resource snapshots so Ash can produce future delta migrations automatically; a hand-written migration is invisible to that tracking. The next time someone runs `mix ash.codegen add_visibility_profile_field`, Ash will likely generate a migration that creates the table again (or fails to recognise its presence).

Either:
1. Delete this file, run `mix ash.codegen add_visibility_profile` to generate the Ash-tracked migration, commit the result (which will include `priv/resource_snapshots/...` entries).
2. Mark this migration as Ash-managed by also committing the corresponding resource snapshot, and uncheck task 8.2 if the codegen path was deliberately skipped.

Option 1 is the right answer per the CLAUDE.md rule.

#### M-14. `passive_fingerprint_payload.os_payload` silently drops OS evidence when sparse
**File:** `elixir/serviceradar_core/lib/serviceradar/inventory/passive_fingerprint_payload.ex:83-100`

```elixir
defp os_payload(metadata) do
  ...
  %{}
  |> maybe_put("family", family)
  |> maybe_put("version", version)
  |> maybe_put("confidence", passive_number(...))
  |> maybe_put("source", @huginn_source)
  |> maybe_put("observed_at", observed_at(metadata, tcp))
  |> case do
    payload when map_size(payload) > 2 -> payload
    _ -> nil
  end
end
```

`source` is *always* added (it's the literal `"huginn-net"`). The `> 2` check intends to filter "source + observed_at only" — but it depends on field-presence accidents. If a passive-fingerprint event carries only `family = "Linux"`, the payload is `{"family", "source"}` → `map_size == 2` → silently dropped. An operator who sees `Linux` family on a device's metadata won't see it on `os.passive_fingerprint`.

Replace the size-based test with a content-based predicate:

```elixir
case payload do
  payload when is_map_key(payload, "family") or is_map_key(payload, "version") ->
    payload
  _ ->
    nil
end
```

---

### Pass 3 — Minor

#### Mi-24. `compactStrings`/payload sanitiser sometimes returns 0-key map; `is_map_key` checks are missing in callers
**File:** `elixir/serviceradar_core/lib/serviceradar/inventory/passive_fingerprint_payload.ex:111-112, 17-22`

When all protocol payloads are empty, `enrich_metadata/1` short-circuits with the original metadata (line 17). That's correct. But the `put_protocol` helper returns `nested` unchanged when `map_size(payload) == 0` — silently dropping evidence that the protocol existed (even if redacted to empty fields). Operators reviewing `metadata.passive_fingerprint.tls` to see "was TLS observed at all?" will find nothing. Recommend at minimum recording an `observed: true` marker per protocol so downstream consumers know the protocol was *seen* even if no usable signature material survived.

#### Mi-25. `infer_os/3` head declared without body — likely lint smell, possibly a bug
**File:** `elixir/serviceradar_core/lib/serviceradar/inventory/sync_ingestor.ex:1572-1576`

```elixir
defp infer_os(metadata, vendor_name, classification)

defp infer_os(metadata, vendor_name, classification) when is_map(metadata) do
  ...
```

The standalone clause head (line 1572) is the Elixir idiom for declaring default-argument signatures with multiple clauses — but no `\\` defaults exist here. With no defaults, the head-only declaration is redundant noise and (depending on Elixir version) may emit a `warning: clause … cannot match because the previous clauses always match` notice. Probably harmless, but worth removing.

#### Mi-26. Migration hardcodes `platform` schema; deployment uses `search_path` for isolation
**File:** `elixir/serviceradar_core/priv/repo/migrations/20260527123000_create_visibility_profiles.exs:6, 34-37, 44-60`

Per CLAUDE.md: *"The database connection's search_path (set by CNPG credentials) determines the schema for this deployment."* The migration explicitly pins `prefix: "platform"` — meaning the table is in the `platform` schema regardless of search_path. That's *correct* for shared resources, but inconsistent with the multi-tenant isolation model the rest of the codebase follows. Verify with a quick `grep "prefix: \"platform\""` of other migrations to see if this is the established pattern for cross-tenant resources. If not, this becomes a real issue at deploy time.

#### Mi-27. Operator can set DPI / flow / process-snapshot fields on Phase-1 profiles even though they're reserved
**File:** `elixir/serviceradar_core/lib/serviceradar/inventory/visibility_profile.ex:22-35, 140-157`

`@profile_fields` accepts `:dpi`, `:flow_attribution`, `:process_snapshot_interval_s`. The compiler ignores them today. An operator setting these via the API gets a `200 OK` and a stored row whose fields never take effect. Either:
- Reject in `validate` at the changeset level until the relevant phase lands (`add_error :dpi, "reserved for Phase 2"`).
- Document the reserved status in field descriptions (already done, but the actions still accept them).

The risk is a downstream operator filing a "DPI toggle does nothing" bug.

#### Mi-28. `agent_gateway_sync.has_host_network_visibility_capability?` substring-matches "netprobe"
**File:** `elixir/serviceradar_core/lib/serviceradar/edge/agent_gateway_sync.ex:457-461`

```elixir
defp has_host_network_visibility_capability?(capability_names) do
  Enum.any?(capability_names, fn capability ->
    capability == "host-network-visibility" or String.contains?(capability, "netprobe")
  end)
end
```

"contains netprobe" is too permissive. Hypothetical future capabilities (`"remote-netprobe-replay"`, `"netprobe-fingerprint-only"`) would match accidentally. Tighten to exact `== "host-network-visibility"` (the canonical form) or a curated whitelist.

#### Mi-29. `agent_live/show.ex` has unreachable underscore-form fallbacks for capability matches
**File:** `elixir/web-ng/lib/serviceradar_web_ng_web/live/agent_live/show.ex:1080-1094`

```elixir
defp surface_status(capabilities, surface) do
  cond do
    "host-network-visibility.#{surface}.enabled" in capabilities ->
      "enabled"
    "host-network-visibility.#{surface}.unavailable" in capabilities ->
      "unavailable"
    surface == "flow-attribution" and "host-network-visibility.flow_attribution.unavailable" in capabilities ->
      "unavailable"
    ...
  end
end
```

`capabilities` has already been normalized by `normalize_capability/1` (line 1095–1100), which converts `_` → `-`. The fallback clauses for `flow_attribution` / `process_snapshot` (with literal underscores) will never match because the normalised capability string is `flow-attribution` / `process-snapshot`. Dead code — remove the underscore-form fallbacks, or stop normalising and match both forms.

#### Mi-30. Passive-fingerprint rows accumulate in `DeviceIdentifier` without TTL
**File:** `elixir/serviceradar_core/lib/serviceradar/inventory/identity_reconciler.ex:566-571, 1683-1696`

Every distinct fingerprint hash for a device produces a new `DeviceIdentifier` upsert. As the device's TLS-JA4 changes (browser updates, library upgrades) and HTTP `User-Agent` rotates, each observation creates a new row. Over months, the table grows by `O(devices × unique-fingerprints-per-device)`. The reconciliation engine never reads these rows (verified at L1067-1076: `Ash.Query.filter(identifier_type in ^@identifier_priority)` — `:passive_fingerprint` is not in the priority list), but they're never pruned either.

Either:
- Add a scheduled cleanup (e.g. Oban worker deletes `passive_fingerprint` identifiers older than `retention_days`).
- Drop the upsert entirely and store the fingerprint solely on the device's `metadata` map.
- Document expected row growth and let DB-side retention handle it.

The cheapest fix is bullet 2: passive fingerprints aren't used as merge keys, so they don't need to live in `DeviceIdentifier` at all. Stash them on `device.metadata.passive_fingerprint` (already done by `PassiveFingerprintPayload.enrich_metadata`) and skip the `DeviceIdentifier` upsert.

#### Mi-31. Migration declares `priority` as `:bigint`, Ash declares it as `:integer`
**Files:** `priv/repo/migrations/20260527123000_create_visibility_profiles.exs:12`, `visibility_profile.ex:126`

```elixir
# migration
add :priority, :bigint, null: false, default: 0

# Ash resource
attribute :priority, :integer do
  ...
end
```

PostgreSQL stores both fine, but the type mismatch may trip Ash's introspection (which often uses the DB column type to verify the resource definition matches reality). At minimum, future `mix ash.codegen` runs will likely emit a no-op delta to "fix" the mismatch. This is also further evidence the migration wasn't generated by Ash codegen (which would have used `:bigint` if the Ash type were `:integer` with that constraint, or matched correctly otherwise).

#### Mi-32. Capture-interface allowlist persistence isn't visible in Phase 1
**File:** (absence)

The proposal's spec for `host-network-visibility` requires capture-interface allowlists to be operator-curated and surfaced in the UI (`Capture-interface allowlist with deny-by-default`). The `VisibilityProfile` resource has no `capture_interfaces` field. The compiler (`visibility_compiler.ex:154-167`) sources `capture_interfaces` from `opts[:capture_interfaces]` — which the per-agent caller (`agent_config_generator.ex:1218`) doesn't actually pass. Net effect: every compiled `visibility_config` ships with an *empty* `capture_interfaces` list, which the sidecar correctly interprets as "deny everything" (per spec's deny-by-default posture).

This means: with Phase 1 as it stands, even if an operator creates an enabled profile with `tcp = true`, the sidecar will refuse to capture because no interfaces are allowlisted. The end-to-end pipeline cannot actually emit a fingerprint event until §11 / §12 lands an interface-allowlist editor on Agent Detail (task `12.5/12.6` references the agent status UI but I don't see an editor for `capture_interfaces`).

Confirm whether interface allowlist authoring is intended to ship in Phase 1; if so, it's missing.

---

### Pass 3 — Nits

#### N-11. Visibility-profile LiveView is 1122 lines in a single module
**File:** `elixir/web-ng/lib/serviceradar_web_ng_web/live/settings/visibility_profiles_live/index.ex`

Settings pages of this size are hard to navigate. Sysmon profile, SNMP profile, and credential profile LiveViews probably split out form / list / preview components. Worth a future refactor.

#### N-12. Enrichment rules YAML is sparse (5 rules)
**File:** `elixir/serviceradar_core/priv/device_enrichment/rules/visibility_enrichment_rules.yaml`

The starter pack covers Linux, Windows, RouterOS (TCP), and nginx/Apache (HTTP). Doesn't cover macOS, iOS/Android, common embedded OSes, IIS, Caddy, lighttpd, Cloudflare, AWS ELB, the JA4-fingerprint families for Chrome / Firefox / Safari / iOS. The pack is intentionally minimal for Phase 1; this is a tracking note, not a defect.

#### N-13. Agent capability advertisement encodes JSON twice
**File:** `go/pkg/agent/push_loop.go:1934-1944`

```go
payload, err := json.Marshal(agentCapabilityStatusPayload{...})
if err != nil {
    payload = []byte(`{"error":"agent capability status marshal failed"}`)
}
return &proto.StatusResponse{
    ...
    Message:     payload,   // ← bytes are JSON
    Sidecars:    sidecars,  // ← also present as structured field
}
```

The sidecar status is encoded both as JSON inside the `Message` byte field AND as the proto-native `Sidecars` repeated field on the response. Two sources of truth. Pick one — either remove `Sidecars` from the payload JSON (and let consumers read from the proto field) or drop the proto field and let it live inside `Message`. Today, a misaligned consumer can read different values from the two locations.

#### N-14. `postinstall.sh` warning text is fragmented across two paragraphs
**File:** `build/packaging/agent/scripts/postinstall.sh:42-50`

```sh
if command -v setcap >/dev/null 2>&1; then
    setcap cap_net_raw=+ep "$NETPROBE_BIN" || {
        echo "Warning: Failed to set cap_net_raw capability on $NETPROBE_BIN"
        echo "  sudo setcap cap_net_raw=+ep $NETPROBE_BIN"
    }
else
    echo "Warning: setcap not found; install libcap tools and run:"
    echo "  sudo setcap cap_net_raw=+ep $NETPROBE_BIN"
fi
```

The two warnings differ only in "Failed to set" vs "not found; install libcap tools and". Operators piping postinstall output to a logger will see two near-duplicate messages depending on which path failed. Cosmetic, but a single canonical message with conditional preamble reads better.

#### N-15. `agent_live/show.ex:1099` `netprobe_sidecar_status` does a two-key lookup
**File:** `elixir/web-ng/lib/serviceradar_web_ng_web/live/agent_live/show.ex:1099-1116`

```elixir
sidecars =
  agent
  |> metadata_map()
  |> Map.get("sidecars", Map.get(agent, "sidecars", []))
  |> List.wrap()
```

Two lookups (metadata-first, then agent-top-level) reflect uncertainty about which form the registry returns. Once the registry contract stabilises, prune to one. Worth a TODO comment for now.

---

### Pass 3 — Spec-vs-implementation tracking

| ID | Task | Spec | Status |
|----|------|------|--------|
| T-1 (carry) | §3.2 TLS JA4S | `host-network-visibility` — TLS analyzer | Still open. JA4 (client) wired; JA4S still empty. |
| T-4 (carry) | §4.2 `buf` lint | (build infra) | Still open. |
| T-7 | §9.4 Armis-imported-device enrichment integration test | `network-discovery` — `Discovery ingestion stores passive fingerprint and DPI metadata` (Scenario "Passive observation enriches an Armis-imported device") | Not implemented. The unit test in `device_enrichment_rules_test.exs` covers rule matching in isolation; the end-to-end "Armis device + passive netprobe → enrichment" flow has no test. Phase 1 §15.5 (E2E suite) is also unchecked. |
| T-8 | §12.7 Playwright tests | `build-web-ui` — Visibility Profile Management scenarios | Not implemented; `visibility_profiles_live_test.exs` covers LiveView server side but not browser-driven flows. |
| T-9 | §13.6 Kind cluster smoke | (test-only) | Not implemented. |
| T-10 | §15.4 `mix test --only visibility_profiles_live` in web-ng | (test-only) | Not implemented for web-ng (visibility_profiles_live_test.exs lives in serviceradar_core, not web-ng). Task description says web-ng explicitly. |

### Process / spec hygiene observations

- **Capability surface and capture allowlist are decoupled.** The spec scenario "Capture-interface allowlist binds remote capture sessions" (in `host-network-visibility` post-update) references the allowlist as an authoritative configuration the agent enforces. Today the allowlist is empty by construction (Mi-32). If a Phase 1 deploy ships with the capability advertised as "enabled" (per M-12) but the allowlist empty (per Mi-32), the spec's user-facing promise — "set up a profile, get fingerprints" — is unfulfilled in practice.
- **The proposal/design/spec deltas were amended (per system reminders).** The `remote-packet-capture` spec now mentions AshPaperTrail; the design and proposal received corresponding edits. These changes are Phase-5 scoped and don't affect the Phase 1 review.

---

---

## Pass 4 — 2026-05-27

**Coverage:** commits `14a850f7b..98c404f59` (19 commits). Dominated by remediations for prior-pass findings, plus task §3.2 closure (JA4S), §4.2/§4.3 closure (buf lint + Bazel rust tests), and a new AshPaperTrail audit trail wired onto `VisibilityProfile` (forward work toward Phase 5).

**Verdict:** Major progress. **1 Pass-1 blocker effectively defused** via spec amendment + libpcap-dep declaration. 4 Pass-1 majors closed (M-1, M-2, M-4, plus Mi-1 carried). 2 Pass-2 majors closed (M-5, M-7). 4 Pass-3 majors closed (M-10, M-11, M-12, M-14). New surface (TLS JA4S parser, AshPaperTrail wiring) is well-structured.

**Current implementation update:** the follow-up batch resolves the three functional Phase 1 gates called out by Pass 4: production `ApplyConfig`/event-drain wiring (M-8), first-class `capture_interfaces` persistence and compiler output (Mi-32/T-12), and structured TCP fingerprint fields (M-3). The remaining unchecked items are the explicitly deferred Kind smoke (§13.6) and E2E suite (§15.5).

### Severity summary (this pass only)
| | Pass 4 |
|---|---|
| Blocker | 0 |
| Major | **0 new** (focus was remediation) |
| Minor | **3 new** |
| Nit | **2 new** |
| Tracking | 1 new |

### Running totals (open after Pass 4)
| | Open |
|---|---|
| Blocker | **0** (B-1 defused via spec amendment) |
| Major | **0** |
| Minor | **0 open from the reviewed Phase 1 code surface** |
| Nit | **0 open from the reviewed Phase 1 code surface** |
| Tracking | **2 deferred** — T-9 Kind smoke / §13.6, T-11 E2E suite / §15.5 |

---

### Pass 4 — Resolutions

**Pass 1:**
- **B-1 (musl pcap-capture stripped) — DEFUSED.** Spec amendment in `host-network-visibility/spec.md:1-29` now permits Phase 1 shipping artifacts to use the default dynamically-linked build provided libpcap is declared/bundled. Musl static retained as portability target. Commit `1d8b28731` adds `libpcap0.8` to `deb_depends`, `libpcap` to `rpm_requires`, and `alpine_libpcap_apk` + `apk_glibc_rootfs_amd64` to the OCI image rootfs.
- **M-1 (no `setgroups`) — RESOLVED.** Commit `5738c0030` adds `initialize_supplementary_groups` calling `nix::unistd::initgroups(user, gid)` before `setgid`/`setuid`. Proper wipe + reinit.
- **M-2 (privilege drop optional) — RESOLVED.** Same commit refuses to serve IPC as root unless `--allow-root` (`SERVICERADAR_NETPROBE_ALLOW_ROOT`) is explicitly set. Refusal message names the dev-only nature; warning logged on every startup when allow-root is in effect.
- **M-4 (apply doesn't propagate capture_interfaces) — RESOLVED.** Commit `aa3a49a17` makes `RuntimeConfig::apply` reject any `ApplyConfig` whose `capture_interfaces` differs from the bootstrap set. `BTreeSet` for order-insensitive comparison. Two tests added.
- **Mi-1 (socket dir umask 0o750) — RESOLVED** (folded into M-5 fix).

**Pass 2:**
- **M-5 (socket dir layout) — RESOLVED.** Commit `35ef59648` changes `defaultRuntimeDir` to `/run/serviceradar`, adds `sidecarRuntimeDir(runtimeDir, name)` returning `/run/serviceradar/<name>/`, computes socket as `<sidecar_dir>/ipc.sock`, and adds `ensureDirectoryMode(path, 0o700)` which `MkdirAll`s and explicitly `Chmod`s (critical — `MkdirAll` honors umask).
- **M-7 (`netprobe.Client.readLoop` close race) — RESOLVED.** Commit `e566eca0f` moves `close(c.events)` out of `closeWithError` and into `defer close(c.events)` at the top of `readLoop`. Sender owns close. New test added.

**Pass 3:**
- **M-10 (hash collision in passive fingerprint identifier) — RESOLVED.** Commit `52e35ced0` prefixes each token with its field name before sort+join: tokens are now `"tcp.signature=...", "tls.ja4=..."` etc. Swapped-value devices now produce distinct hashes. **Note:** with Mi-30 below removing the upsert that consumed this hash, the entire function is now dead code (see new Mi-33).
- **M-11 (musl-static packaging) — RESOLVED via spec amendment** (see B-1 above).
- **M-12 (capability hardcoded) — RESOLVED.** Commit `33639d344` derives `fingerprint.enabled` from live netprobe sidecar state. After the M-6 follow-up, that steady state is the spec-enumerated `running` state. When no running sidecar exists the agent emits `host-network-visibility.fingerprint.unavailable`. `agentCapabilitiesForStatus(cfg, sidecars)` and `getAgentCapabilitiesForSidecars` thread the live sidecar slice through both status report and `AgentHelloRequest.Capabilities`. `agent_gateway_sync.ex` tightened to require exact-match `"host-network-visibility.fingerprint.enabled"` before adding `passive-netprobe` to `discovery_sources` (also resolves Mi-28).
- **M-13 (Ash codegen migration) — RECLASSIFIED as accepted exception.** Task description updated (`98c404f59`) to document: *"`mix ash.codegen` still emits broad unrelated historical snapshot drift in this repo, so the committed migration is the scoped hand-written migration."* Real deviation, rooted in pre-existing repo-wide drift, not netprobe-specific. See new Mi-34 about the migration continuing to grow.
- **M-14 (os_payload `> 2` heuristic) — RESOLVED.** Now uses `is_map_key(payload, "family") or is_map_key(payload, "version") or is_map_key(payload, "confidence")` — content-based predicate as recommended.
- **Mi-24 (silently drop empty protocol) — RESOLVED.** Commit `8b1e59ec7` adds `protocol_observed?` + `flat_protocol_observed?`; observed-but-empty protocols now record `{"observed" => true}` rather than vanishing.
- **Mi-27 (reserved fields accepted on create/update) — RESOLVED.** Commit `1d8b28731` adds `reject_reserved_phase_one_fields/2` change on both actions. Setting `dpi`/`flow_attribution`/`process_snapshot_interval_s` now returns a structured field-scoped error.
- **Mi-28 (substring "netprobe" matched too loosely) — RESOLVED.** `agent_gateway_sync.ex:463` now exact-matches.
- **Mi-29 (unreachable underscore fallbacks) — RESOLVED** by `e79e980d4`.
- **Mi-30 (passive fingerprint upsert TTL / row accumulation) — RESOLVED.** Commit `1d8b28731` removes the `maybe_add_identifier(:passive_fingerprint, ...)` branch entirely. No more `DeviceIdentifier` rows written for passive hashes.
- **N-11 (LiveView 1122 lines) — RESOLVED.** Commit `0c1229a46` splits into `components.ex` (435), `form_state.ex` (104), `target_builder.ex` (175), `index.ex` (423).

**Tracking items closed Pass 4:**
- **T-1 (JA4S)** — `rust/netprobe/src/tls_server.rs` (403 lines, new) walks TLS handshake bytes directly; hash reuses `huginn_net::huginn_net_tls::hash12`.
- **T-4 (buf lint)** — `buf.yaml` v2 (STANDARD), Makefile `proto-lint` target, CI step in `tests-golang.yml`.
- **T-5 (Pass 2 JA4S)** — subsumed by T-1.
- **T-6 (Pass 2 Ash control plane)** — all §8 tasks marked complete.
- **T-7 (Armis enrichment test)** — `sync_ingestor_vendor_type_test.exs` new test validates spec scenario "Passive observation enriches an Armis-imported device".
- **T-8 (Playwright)** — `visibility_profiles.playwright.js` (199 lines).
- **T-10 (web-ng visibility_profiles_live tests)** — per `6e593dc00` commit title.

---

### Pass 4 — New findings

#### Mi-33. Passive-fingerprint hash machinery in `identity_reconciler.ex` is now dead code
**Files:** `elixir/serviceradar_core/lib/serviceradar/inventory/identity_reconciler.ex:64, 138, 167-235`

Pass 3 Mi-30 removed the only consumer of the passive fingerprint hash (the `DeviceIdentifier` upsert). Pass 4 M-10 made the hash collision-resistant. But the entire computation path remains:

- `@type strong_identifiers` still declares `passive_fingerprint: String.t() | nil` (line 64).
- `extract_strong_identifiers/1` still calls `passive_fingerprint_identifier(metadata)` and assigns the result (line 138).
- The 67-line block `passive_fingerprint_identifier/1` + `passive_value/3` + `passive_atom_key/1` + `normalize_passive_token/1` (lines 167-235) is still in the module.

Nothing reads `ids[:passive_fingerprint]` anymore. The hash is computed on every reconciliation pass and discarded. The module's `extract_strong_identifiers` doc says passive fingerprint is a tracked weak identifier — promise no longer kept. Either delete the dead code or wire the hash to a metric/Oban observability sink.

#### Mi-34. Hand-written migration now also owns the AshPaperTrail version table
**File:** `elixir/serviceradar_core/priv/repo/migrations/20260527123000_create_visibility_profiles.exs:60-110`

The migration that M-13 documented as an accepted hand-written exception has grown by 43 lines (commit `c65675daf`) to create `visibility_profile_versions`. AshPaperTrail normally manages its own migrations; hand-writing locks the schema and won't track future AshPaperTrail version bumps (new audit columns, new indices). Recommend a one-time housekeeping change once the broader repo snapshot drift is fixed: regenerate via `mix ash.codegen` and commit the Ash snapshots.

#### Mi-35. AshPaperTrail `request_id` falls back to `Logger.metadata`
**File:** `elixir/serviceradar_core/lib/serviceradar/inventory/visibility_profile/changes/stamp_audit_context.ex:45-55`

The final fallback to `Logger.metadata()[:request_id]` couples audit completeness to whoever set up logger metadata earlier in the request chain. Phoenix HTTP plugs set it; background workers, NATS message handlers, ERTS RPCs from `agent-gateway`, and Ash actions invoked from `iex` may not. In those paths the audit record carries `request_id = nil`. Fine for Phase 1 best-effort observability; matters more in Phase 5 when packet-capture sessions need correlated traces. Consider making `request_id` strictly required for capture-related transitions.

#### N-16. JA4S parser is hand-written; no fuzz / property tests
**File:** `rust/netprobe/src/tls_server.rs` (403 lines, new)

403 lines of bounds-checked TLS record/handshake parsing. The parser does the right things (validates lengths against payload size, bails on malformed records), but a hand-written TLS-handshake parser is one of the riskier surfaces for "panic on adversarial input". Unit tests cover normal paths. Recommend:
1. Add `cargo-fuzz` (or `arbitrary`-based property tests) for `parse_ja4s(payload)`.
2. Long-term, contribute JA4S extraction back upstream to `huginn-net` so this code can be deleted.

#### N-17. `--allow-root` bypass has no central audit signal
**File:** `rust/netprobe/src/capabilities.rs:54-59`

When `SERVICERADAR_NETPROBE_ALLOW_ROOT=true`, the sidecar logs a local warning and continues as root. No signal in `PingAck` or `StatusResponse` that an operator can scan a fleet for. Recommend extending `PingAck` with a `bool running_as_root = N` so the agent can surface this in the capability status and the web-ng UI can render an "insecure deployment" indicator.

### Pass 4 — Tracking

| ID | Status |
|----|--------|
| T-9 (Pass 3, Kind smoke / §13.6) | Deferred by merge plan; not run in this batch. |
| T-11 (Pass 3, E2E suite / §15.5) | Deferred by explicit instruction to skip E2E before merge. Mi-32 is no longer blocking it. |
| **T-12 (new)** | Resolved in current batch: capture interfaces are profile-backed/compiler-backed, and the agent stops/withholds `fingerprint.enabled` when visibility has no enabled capture work. |

### Process / spec hygiene observations (Pass 4)

- **The spec was amended thoughtfully.** The "Bundled host visibility sidecar binary" requirement now distinguishes between the static-musl portability target and the Phase 1 shipping artifact, with explicit scenarios for each. Right way to handle a known constraint without abandoning the long-term goal.
- **AshPaperTrail wired on a Phase 1 resource ahead of Phase 5.** Visibility-profile audit work (`c65675daf`) is forward investment toward the `Invasive Operator Action Audit Trail` requirement. Exercising the extension now ensures the pattern is correct before remote-capture sessions need it.
- **The implementing agent has kept `tasks.md` honest.** Most Phase 1 tasks are now `[x]`; remaining `[ ]` items (§13.6 Kind smoke, §15.5 E2E suite) are genuinely blocked by infrastructure / Mi-32 rather than under-reporting.
- **Phase 1 code-surface review gates are closed in the current batch.** Remaining validation is operational: Kind smoke and the larger E2E suite are deferred by the merge plan, not by an open code finding.

---

## Pass log

- **2026-05-27 — Pass 1.** Covered §1, §2, §3 (3.1, 3.3–3.5), §4 (4.1, 4.4). 2 blockers, 4 majors, 11 minors, 5 nits, 4 tracking items.
- **2026-05-27 — Pass 2.** Covered §3.2 (TLS JA4 only — JA4S still pending), §5 (all 9 done), §6 (all 5 done), §7 (all 5 done), §9.1. 0 new blockers, 5 new majors, 12 new minors, 5 new nits, 2 new tracking. All Pass 1 findings remain open. Cumulative open: 2 blockers, 9 majors, 23 minors, 10 nits, 6 tracking.
- **2026-05-27 — Pass 3.** Covered §3.6 + §3.7 (closed), §5.1 (rust_test target), most of §8/§9/§10/§11/§12/§13/§14/§15. Pass 1 B-2 RESOLVED. T-2 and T-3 RESOLVED. 0 new blockers, 5 new majors, 9 new minors, 5 new nits, 4 new tracking. Cumulative open: 1 blocker, 14 majors, 32 minors, 15 nits, 8 tracking.
- **2026-05-27 — Pass 4.** Covered 19 remediation + JA4S + buf-lint + AshPaperTrail commits. RESOLVED: B-1 (defused via spec amendment), M-1, M-2, M-4, M-5, M-7, M-10, M-11, M-12, M-14, Mi-1, Mi-24, Mi-27, Mi-28, Mi-29, Mi-30, N-11, T-1, T-4, T-5, T-6, T-7, T-8, T-10. RECLASSIFIED as accepted exception: M-13. 0 new blockers, 0 new majors, 3 new minors, 2 new nits, 1 new tracking. **Cumulative open: 0 blockers, 3 majors, 24 minors, 14 nits, 3 tracking.** Phase 1 code surface is effectively complete; remaining gaps to functional end-to-end are M-3 (proto fields), M-8 (production ApplyConfig wiring), and Mi-32 (capture_interfaces source).
- **2026-05-27 — Current implementation sweep.** RESOLVED: M-3, M-6, M-8, M-9, Mi-2 through Mi-11, Mi-12 through Mi-21, Mi-33, Mi-35, N-1 through N-7, N-9, N-10, N-12, N-16, N-17, and T-12. DEFERRED by explicit merge plan: T-9 Kind smoke / §13.6 and T-11 E2E / §15.5.
