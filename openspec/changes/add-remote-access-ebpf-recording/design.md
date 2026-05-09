## Context
ServiceRadar now has a generic remote-access substrate and an `EnhancedRecorder` interface. The Linux implementation currently provides a procfs fallback collector for command, open-file descriptor, and socket observations when policy permits fallback. That is useful for development and degraded environments, but it cannot satisfy enterprise policies that require BPF-backed enhanced recording.

Teleport is a useful architecture reference, but not a safe current import target for this path. The local `~/src/teleport` checkout shows:

- `v14.4.0` commit `8113e07dc94cf2977247346d5ec28ca0d5753c54` includes Apache-2.0 headers on sampled `lib/bpf/*.go` files.
- `v15.0.0` commit `e126e8cd7165f26ab724aaa58f285120db8e38e5` and current `HEAD` use AGPL headers on sampled `lib/bpf/*.go` files.
- `bpf/enhancedrecording/*.bpf.c` uses kernel BPF probe code and should still be treated carefully; ServiceRadar should prefer its own probe source unless legal and dependency review explicitly approve a copied Apache-era file.

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

The preferred dependency direction is to standardize on one maintained Go eBPF library, with `github.com/cilium/ebpf` as the leading candidate because it is broadly used, Go-native, and compatible with CO-RE style workflows. The final dependency still needs license, transitive dependency, Bazel, cross-compile, kernel support, and operational review before it is introduced.

The shared runtime should own:

- Program load and attach lifecycle.
- Map creation, pinning policy, and cleanup.
- Ring-buffer/perf-buffer readers and backpressure handling.
- Kernel feature detection and startup self-tests.
- Capability reporting inputs for `remote_access.bpf` and future BPF-backed capabilities.
- Common metrics, logging, and loss counters.

Remote-access enhanced recording should contribute session-scoped probes and event normalization on top of that runtime, not a separate runtime.

### Session Scoping
The collector should scope monitoring to the session process tree using a cgroup membership map or equivalent kernel-visible session token. The first implementation should prefer cgroup scoping because it gives a stable kernel-side filter across execs and child processes. If an adapter cannot provide a session cgroup/process boundary, required BPF policies must fail closed for that adapter until it does.

The agent must remove the session identifier from BPF maps when the session closes, expires, or fails during open.

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

### Licensing
Any source copied from Teleport v14 must have a provenance note in the introducing commit or design comment that records tag, commit, file path, header, and dependency scan. Current Teleport v15+ and `HEAD` `lib/bpf` implementation paths are AGPL and are clean-room reference only.

The preferred implementation path is ServiceRadar-authored code using public Linux eBPF APIs and a single Apache-2.0/MIT-compatible agent eBPF library after Bazel and Go module review. Avoid introducing a second eBPF runtime later for network, flow, security, or host-observability work unless the existing runtime has a documented technical blocker.

## Test Strategy
- Unit tests for policy fail-closed behavior, capability checks, event normalization, redaction, and dropped-event accounting.
- Linux integration tests behind an explicit build tag or environment variable that load probes on compatible hosts.
- A remote-access smoke test that starts a short-lived SSH session, executes a known command, opens a known file, attempts a known network connection, and verifies correlated events.
- Negative smoke tests for unavailable BPF, missing permissions, incompatible kernels, and policy fallback behavior.
- Bazel coverage for normal builds without BPF and Linux BPF-enabled builds.
