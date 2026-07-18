## Context
ServiceRadar now has a generic remote-access substrate and an `EnhancedRecorder` interface. The Linux implementation currently provides a procfs fallback collector for command, open-file descriptor, and socket observations when policy permits fallback. That is useful for development and degraded environments, but it cannot satisfy enterprise policies that require BPF-backed enhanced recording.

Teleport is a useful architecture reference, but not a safe current import target for this path. The local `~/src/teleport` checkout shows:

- `v14.4.0` commit `8113e07dc94cf2977247346d5ec28ca0d5753c54` includes Apache-2.0 headers on sampled `lib/bpf/*.go` files.
- `v15.0.0` commit `e126e8cd7165f26ab724aaa58f285120db8e38e5` and current `HEAD` use AGPL headers on sampled `lib/bpf/*.go` files.
- `bpf/enhancedrecording/*.bpf.c` uses kernel BPF probe code and should still be treated carefully; ServiceRadar should prefer its own probe source unless legal and dependency review explicitly approve a copied Apache-era file.

Teleport v14 provenance recorded for this proposal:

| Teleport ref | Paths inspected | Header/license finding | ServiceRadar use |
| --- | --- | --- | --- |
| `v14.4.0` / `8113e07dc94cf2977247346d5ec28ca0d5753c54` | `lib/bpf/bpf.go`, `common.go`, `common_linux.go`, `command.go`, `disk.go`, `network.go`, `helper.go` | Apache-2.0 headers in sampled files | Architecture reference; copying requires a dedicated provenance note and dependency scan in the implementation commit. |
| `v14.4.0` / `8113e07dc94cf2977247346d5ec28ca0d5753c54` | `bpf/enhancedrecording/command.bpf.c`, `disk.bpf.c`, `network.bpf.c`, `common.h` | Probe files use kernel BPF licensing conventions; sampled probes include dual BSD/GPL license strings where helpers require it | Behavior reference only by default; prefer ServiceRadar-authored probes with explicit SPDX headers. |
| `v15.0.0` / `e126e8cd7165f26ab724aaa58f285120db8e38e5` and current `HEAD` | `lib/bpf/bpf.go`, `common.go`, `command.go`, `disk.go`, `network.go` | AGPL headers in sampled files | Clean-room reference only. Do not copy, translate, or mechanically port. |

The inspected Teleport v14 behavior patterns are cgroup-scoped monitoring, separate command/disk/network probe families, ring-buffer event delivery, and loss counters. These are requirements-level references only; ServiceRadar implementation should be written from public Linux eBPF interfaces, this OpenSpec, and ServiceRadar tests unless an Apache-era file is explicitly imported with provenance.

Current ServiceRadar findings:

- The Go agent has no existing eBPF runtime package. `go/pkg/scan` uses classic socket BPF directly through `golang.org/x/sys/unix`; that should stay separate from the eBPF runtime unless later work deliberately unifies shared packet-filter helpers.
- Dockerfiles contain historical Rust eBPF/profiler build references, but this checkout does not contain an active `rust/ebpf` source tree. New agent eBPF work should therefore start from a Go agent runtime unless another active owner revives that Rust path.
- `MODULE.bazel` already registers an LLVM toolchain, which is useful for hermetic probe generation, but normal agent builds should not require a host LLVM installation.
- The Helm chart's current agent security profile supports `hostNetwork` and optional `NET_RAW` for network probing, but it does not mount bpffs/cgroupfs or grant BPF-specific privileges. The legacy demo base manifest has used a privileged agent container, but the Helm path should introduce an explicit BPF profile instead of treating privileged mode as the default.

## Goals
- Implement ServiceRadar-owned Linux eBPF enhanced recording for remote-access sessions.
- Capture command execution, file open/access attempts, network connection attempts, and dropped-event counters.
- Correlate every emitted event to the remote-access session, actor, target, agent, and policy snapshot.
- Limit collection to the session boundary rather than all host activity.
- Fail closed before target dial when policy requires BPF and the collector cannot start.
- Avoid plaintext credential capture, terminal input capture, and file-content capture.
- Choose a reusable `serviceradar-agent` eBPF runtime/loader strategy that future ServiceRadar eBPF features can share.
- Keep all non-Linux agents functional without BPF capability advertisement.

## Non-Goals
- Do not copy or mechanically port current Teleport AGPL implementation code.
- Do not add a generic host EDR product or host-wide telemetry pipeline in this change.
- Do not require BPF for every remote-access session; policy decides whether BPF is required, optional, or disabled.
- Do not create a remote-access-only eBPF runtime that competes with future agent eBPF collectors.
- Do not persist raw terminal bytes or file contents as enhanced events.

## Architecture
The implementation should extend the existing boundary:

```text
remoteaccess.Manager
  -> EnhancedRecorder
  -> LinuxBPFEnhancedEventSource
  -> eBPF probes + ring buffers
  -> normalized EnhancedEvent frames
```

The agent should start the enhanced recorder before opening the target adapter. If the policy requires BPF and any loader, attach, map, or compatibility check fails, the manager must return a sanitized failure and must not dial the target.

### Shared Agent eBPF Runtime
ServiceRadar expects substantial future eBPF work in `serviceradar-agent`, so this change should not create a bespoke remote-access-only loader, map manager, compatibility checker, or ring-buffer event loop. Remote access should be the first consumer of a shared agent eBPF runtime package or service boundary.

The runtime should live in a package owned by the agent layer, for example `go/pkg/agent/ebpf`, rather than under `go/pkg/agent/remoteaccess`. Remote access may own probe-specific normalization under `go/pkg/agent/remoteaccess`, but program loading, feature detection, map lifecycle, link cleanup, and ring-buffer plumbing should stay in the shared package so later agent features reuse the same operational controls.

The preferred dependency direction is to standardize on one maintained Go eBPF library, with `github.com/cilium/ebpf` as the leading candidate because it is broadly used, Go-native, and compatible with CO-RE style workflows. The final dependency still needs license, transitive dependency, Bazel, cross-compile, kernel support, and operational review before it is introduced.

Initial `github.com/cilium/ebpf` review:

- Latest module observed locally: `v0.21.0`, published 2026-03-05, module Go version `1.24.0`, origin commit `fd33a781ea9ebf9d1bff748707793deccc412c05`.
- Root repository/module license is MIT.
- Runtime packages needed for an agent runtime (`github.com/cilium/ebpf`, `link`, `ringbuf`, `rlimit`, and `features`) pull only `golang.org/x/sys` as an external runtime dependency in a scratch module test.
- The library is documented as pure Go and not dependent on C, libbpf, or cgo.
- `cmd/bpf2go` is the likely probe generation tool, but it is a build-time tool with heavier indirect dependencies. ServiceRadar should generate BPF artifacts hermetically, commit generated `.go` and `.o` outputs, and keep normal `go test`/Bazel agent builds independent of a workstation LLVM setup.
- Scratch compile checks for the runtime imports passed for `darwin/arm64`, `linux/amd64`, and `linux/arm64` without cgo.

Maintenance window:

- Revalidated on 2026-05-18 against GitHub releases and pkg.go.dev: `v0.21.0` is the latest tagged module version and was published on 2026-03-05.
- No newer CVE-only patch release was identified during that review. GitHub release notes for `v0.21.0` call out breaking XDP attach-type changes and compatibility updates, not a post-`v0.21.0` security patch train.
- Because eBPF runs privileged kernel-facing code, ServiceRadar should re-check `github.com/cilium/ebpf` at every ServiceRadar release cut and no later than 12 months after the last documented review.
- A release may keep the pinned version only when the release notes / advisory check finds no relevant security fix and the implementation still compiles against ServiceRadar's supported kernels. Otherwise, upgrade or write a short deferral note that names the blocking API/kernel compatibility issue.

Repository integration path:

- Add `github.com/cilium/ebpf` to `go.mod` only in the implementation change that introduces `go/pkg/agent/ebpf`.
- Run `bazel mod tidy` so `MODULE.bazel` picks up the generated `go_deps` repositories from `go.mod`.
- Keep `go/pkg/agent/ebpf` buildable on non-Linux with stubs, so normal workstation tests and image analysis do not require Linux BPF support.
- Gate real runtime code behind Linux build tags and an explicit ServiceRadar BPF build/runtime enablement check.
- Keep `cmd/bpf2go` as a regeneration tool, not a normal runtime dependency.

The shared runtime should own:

- Program load and attach lifecycle.
- Map creation, pinning policy, and cleanup.
- Ring-buffer/perf-buffer readers and backpressure handling.
- Kernel feature detection and startup self-tests.
- Capability reporting inputs for `remote_access.bpf` and future BPF-backed capabilities.
- Common metrics, logging, and loss counters.

Remote-access enhanced recording should contribute session-scoped probes and event normalization on top of that runtime, not a separate runtime.

Probe source should be ServiceRadar-owned and should carry an explicit SPDX header. Some kernel helpers require a GPL-compatible BPF program license string at load time; if a probe needs those helpers, prefer a dual permissive/GPL BPF program license such as `Dual MIT/GPL` after legal review, while keeping user-space loader code under the ServiceRadar project license.

### Package Ownership
Use this initial package split:

- `go/pkg/agent/ebpf`: shared runtime interfaces, loader wrappers, capability probes, startup self-tests, BPF map/link cleanup, ring-buffer/perf-buffer readers, metrics, and runtime errors.
- `go/pkg/agent/ebpf/probes`: generated probe object bindings and thin constructors for ServiceRadar-owned probe groups. This package should not know about remote-access policy, users, targets, or session state beyond typed map keys/events.
- `go/pkg/agent/remoteaccess`: remote-access policy mapping, session scoping, event redaction, and conversion from typed BPF observations into `EnhancedEvent` frames.

The shared runtime should expose narrow interfaces such as:

- `Runtime.Check(ctx) CapabilityReport`
- `Runtime.LoadCollection(ctx, CollectionSpec) (Collection, error)`
- `Collection.Attach(ctx, AttachPlan) (SessionHandle, error)`
- `SessionHandle.Events() <-chan Observation`
- `SessionHandle.Close(ctx) error`

This keeps future eBPF consumers from importing remote-access packages and keeps remote-access from owning global kernel state.

### Generated Probe Artifacts
Probe source should live in normal source control next to generated artifacts. The expected workflow is:

1. Write ServiceRadar-owned `.bpf.c` probe source with SPDX/license headers.
2. Generate little-endian and big-endian Go/object outputs with `bpf2go` or the selected generator in a hermetic LLVM-capable environment.
3. Commit the generated `.go` and `.o` artifacts.
4. Make normal `go test`, `bazel test`, and container builds consume the checked-in generated artifacts without requiring local clang/LLVM.
5. Provide an explicit regeneration target or script that fails if generated artifacts are stale.

The generated outputs must be deterministic enough for CI to verify. If source paths or DWARF metadata make generation non-deterministic, use stable build containers, controlled `BPF2GO_CFLAGS`, and path-prefix stripping before accepting the generator path.

### Session Scoping
The collector should scope monitoring to the session process tree using a cgroup membership map or equivalent kernel-visible session token. The first implementation should prefer cgroup scoping because it gives a stable kernel-side filter across execs and child processes. If an adapter cannot provide a session cgroup/process boundary, required BPF policies must fail closed for that adapter until it does.

The agent must remove the session identifier from BPF maps when the session closes, expires, or fails during open.

There is an important target-side observability boundary:

- For local shell/session adapters where the ServiceRadar agent starts the PTY process on the same Linux host, the agent can place that process tree in a session cgroup and BPF can observe command, file, and network activity for that session.
- For managed targets that run a ServiceRadar agent or a future ServiceRadar-controlled SSH/session component on the target host, the target-side component can own the cgroup and emit enhanced events for the actual shell process tree.
- For agentless SSH through an intermediate ServiceRadar agent, the selected agent is only an SSH client. It can observe the agent-side SSH client process and network connection, but it cannot BPF-observe commands, file opens, or child processes inside the remote target's sshd session.

Therefore, policies that require command/file eBPF tracing must route only to local-execution or managed-target execution modes. Agentless SSH targets may use lifecycle audit, terminal recording when allowed, SSH certificate audit, host-key audit, and agent-side network observations, but they must not be represented as satisfying target-side command/file BPF requirements.

Session scoping for the first BPF-capable adapter should be:

1. Create or allocate a session cgroup before the target process starts.
2. Register the cgroup/session key in the shared BPF runtime maps.
3. Start the local PTY process or managed target session inside that cgroup.
4. Emit only events whose kernel-side cgroup/session key matches the registered session.
5. Unregister the session key and remove the cgroup on close, timeout, open failure, or agent shutdown.

If a protocol adapter cannot perform those steps, it may still run with BPF disabled or with an explicitly allowed fallback, but it must fail closed when policy requires target-side BPF.

### Event Families
- `command`: exec path, argv subject to policy redaction, cwd when available, uid/gid, pid/ppid, exit code when available, timestamp.
- `file`: path, operation, flags where safe, uid/gid, pid, result/error code, timestamp.
- `network`: source/destination IP and port, protocol, pid, result/error code, timestamp.
- `loss`: ring-buffer drops, map drops, parser failures, and user-space backpressure counters.

All events must reuse the existing `EnhancedEvent` shape or a strictly compatible extension. Metadata must identify the source as `linux_ebpf` and include collector/probe version fields.

### Capability Advertisement
`PlatformEnhancedRecordingAvailable()` may return true only when:

- The binary was built with the BPF collector enabled for Linux.
- The kernel supports the required BPF features.
- Required filesystem mounts and permissions are present.
- The collector can load and attach a minimal self-test probe or an equivalent startup validation passes.

The procfs fallback must not cause `remote_access.bpf` to be advertised.

### Kubernetes and Host Operations
The eBPF runtime should be opt-in at deployment time. `agent.allowNetRaw` is not sufficient and should not imply BPF access. Add a separate future chart value such as `agent.ebpf.enabled` with explicit security and mount choices.

Minimum runtime checks before advertising BPF should include:

- Linux platform and supported architecture.
- Kernel feature checks for the selected program/link/map types.
- Kernel version and syscall availability compatible with the selected attach strategy; CO-RE/BTF support should be validated directly rather than inferred from version alone.
- Readable BTF source for CO-RE loading, usually `/sys/kernel/btf/vmlinux`.
- bpffs availability, usually `/sys/fs/bpf`, with the chart deciding whether it is host-mounted read-write or whether the runtime uses unpinned objects only.
- cgroup v2 or other selected session-boundary mechanism availability.
- Sufficient process permissions/capabilities to load programs, create maps, attach links, and read ring buffers.
- Container security context and seccomp profile compatible with the required BPF syscalls.

Kubernetes deployment guidance:

- Prefer least privilege over blanket `privileged: true`.
- On modern kernels, prefer specific capabilities such as `BPF`, `PERFMON`, and any required tracing/admin capability when the container runtime and Kubernetes version support them.
- Fall back to `SYS_ADMIN` or privileged mode only as an explicitly documented compatibility mode for older kernels or runtimes.
- Mount `/sys/fs/bpf`, `/sys/kernel/btf`, and the selected cgroup filesystem only for agents with BPF enabled.
- Surface disabled reasons in capability reports, for example `missing_bpffs`, `missing_btf`, `kernel_unsupported`, `permission_denied`, or `self_test_failed`.

The default demo Helm values currently set `agent.hostNetwork: false` and `agent.allowNetRaw: false`; that profile should continue to omit `remote_access.bpf`. Demo or lab BPF validation should use an explicit override rather than changing the baseline demo security posture.

This completes the pre-implementation review for `github.com/cilium/ebpf` as the leading shared runtime candidate. The implementation still needs the actual `go.mod`/Bazel changes, generated-probe target, Helm profile, and Linux runtime smoke tests before any release can enable BPF.

### Licensing
Any source copied from Teleport v14 must have a provenance note in the introducing commit or design comment that records tag, commit, file path, header, and dependency scan. Current Teleport v15+ and `HEAD` `lib/bpf` implementation paths are AGPL and are clean-room reference only.

The preferred implementation path is ServiceRadar-authored code using public Linux eBPF APIs and a single Apache-2.0/MIT-compatible agent eBPF library after Bazel and Go module review. Avoid introducing a second eBPF runtime later for network, flow, security, or host-observability work unless the existing runtime has a documented technical blocker.

If an implementation later imports Apache-era Teleport v14 code, it must:

1. Copy only from the recorded Apache-era ref, not from v15+ or current Teleport.
2. Preserve required notices and headers.
3. Document the exact file list and any modifications.
4. Re-run a dependency/license scan for the copied path.
5. Keep the copied code isolated from any AGPL-derived changes.

## Test Strategy
- Unit tests for policy fail-closed behavior, capability checks, event normalization, redaction, and dropped-event accounting.
- Linux integration tests behind an explicit build tag or environment variable that load probes on compatible hosts.
- Build tests that prove checked-in generated BPF artifacts can compile into the agent without local clang, and a separate generation test that runs only in the hermetic LLVM-capable build environment.
- Helm/render tests that prove BPF mounts and capabilities appear only when the explicit BPF profile is enabled.
- A remote-access smoke test that starts a short-lived SSH session, executes a known command, opens a known file, attempts a known network connection, and verifies correlated events.
- Negative smoke tests for unavailable BPF, missing permissions, incompatible kernels, and policy fallback behavior.
- Bazel coverage for normal builds without BPF and Linux BPF-enabled builds.
