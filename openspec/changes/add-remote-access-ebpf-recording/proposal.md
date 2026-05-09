# Change: Add remote-access eBPF enhanced recording

## Why
The completed `add-secure-agent-routed-remote-access` work defines the remote-access tunnel, SSH certificate flow, recording hooks, policy gates, and a Linux procfs fallback collector. It intentionally does not make agents advertise `remote_access.bpf`, because required BPF tracing must be backed by a ServiceRadar-owned collector that can fail closed, correlate events to one session, and avoid AGPL-derived implementation code.

## What Changes
- Add a Linux eBPF enhanced-recording collector behind the existing `EnhancedRecorder` boundary for command, file, network, and loss events.
- Establish a shared `serviceradar-agent` eBPF runtime/loader strategy so remote-access recording, future network telemetry, and future host observability do not grow separate BPF stacks.
- Scope collection to the remote-access session process tree or cgroup so host-wide activity is not over-collected.
- Add kernel/build/runtime compatibility checks before advertising `remote_access.bpf`.
- Keep procfs as an explicit fallback only when policy allows fallback; required BPF policies continue to fail before target dial if BPF cannot start.
- Add tests and smoke tooling that prove event correlation, dropped-event reporting, policy fail-closed behavior, and capability advertisement.
- Record the license provenance for any Teleport v14 Apache-2.0 source consulted or imported, and require clean-room implementation for current Teleport AGPL paths.

## Implementation Gate
The design and dependency review are complete enough for proposal review. Implementation should start only after this change is accepted, and the first implementation slice should build the shared agent eBPF runtime with non-Linux stubs before adding command/file/network probes or advertising `remote_access.bpf`.

## Impact
- Affected specs: `edge-architecture`, `agent-connectivity`
- Affected code: `go/pkg/agent/remoteaccess`, agent capability advertisement, Go/Bazel build rules, Linux-only eBPF build tooling, remote-access smoke tests
- Dependencies: prefer one maintained Apache-2.0/MIT-compatible Go eBPF library for the agent, with `github.com/cilium/ebpf` as the leading candidate pending license, Bazel, kernel, and operational review
