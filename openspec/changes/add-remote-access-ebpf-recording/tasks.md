## 0. Approval
- [x] 0.1 Review and accept this proposal before implementation starts.

## 1. Design and Licensing
- [x] 1.1 Perform initial candidate review for `github.com/cilium/ebpf` license, runtime dependencies, and fit as the shared agent eBPF library.
- [x] 1.2 Complete Bazel, cross-compile, kernel compatibility, and operational review for `github.com/cilium/ebpf` before adding it to `go.mod`.
- [x] 1.3 Record exact Teleport v14 files consulted, if any, with tag, commit, headers, and dependency scan results.
- [x] 1.4 Define the session scoping mechanism for SSH and provider-console adapters, preferring cgroup-scoped monitoring.
- [x] 1.5 Define the checked-in generated artifact strategy for BPF probes so normal agent builds do not require local clang.
- [x] 1.6 Define package ownership for the shared agent eBPF runtime, with remote access consuming it rather than owning it.

## 2. Agent Collector
- [x] 2.1 Add `github.com/cilium/ebpf` to `go.mod`, run `bazel mod tidy`, and keep non-Linux builds working.
- [x] 2.2 Add `go/pkg/agent/ebpf` shared runtime interfaces, non-Linux stubs, Linux capability checks, and runtime error types.
- [x] 2.3 Add Linux-only BPF build plumbing and checked-in generated artifact workflow.
- [x] 2.4 Implement the shared runtime pieces needed by remote-access recording without making them remote-access-specific.
- [x] 2.5 Implement command exec probes and user-space normalization.
- [x] 2.6 Implement file open/access probes and user-space normalization.
- [x] 2.7 Implement network connect probes and user-space normalization.
- [x] 2.8 Implement loss counters for kernel drops, parser failures, and user-space backpressure.
- [x] 2.9 Bind collector lifecycle to remote-access session open/close/timeout paths.

## 3. Policy and Capabilities
- [x] 3.1 Add explicit agent BPF deployment/profile configuration and keep `NET_RAW` separate from BPF enablement.
- [x] 3.2 Make `remote_access.bpf` advertise only after build, kernel, permission, mount, and startup self-test checks pass.
- [x] 3.3 Preserve fail-closed behavior when policy requires BPF and the collector cannot start.
- [x] 3.4 Preserve explicit procfs fallback behavior only when policy allows fallback.
- [x] 3.5 Ensure enhanced events never include private keys, passwords, terminal input bytes, or file contents.
- [x] 3.6 Ensure agentless SSH cannot satisfy target-side command/file BPF requirements unless a managed target component owns the execution boundary.

## 4. Validation
- [x] 4.1 Add unit tests for capability checks, policy gates, redaction, normalization, and loss counters.
- [x] 4.2 Add Linux integration tests behind explicit build tags or environment gates.
- [x] 4.3 Add Helm/render tests that prove BPF mounts and capabilities appear only when the explicit BPF profile is enabled.
- [x] 4.4 Add a remote-access eBPF smoke script that proves command, file, network, and loss event correlation.
- [x] 4.5 Run `go test ./go/pkg/agent/remoteaccess` and focused `go/pkg/agent/ebpf` tests.
- [x] 4.6 Run a BPF-enabled focused test on a compatible Linux host.
- [x] 4.7 Run `openspec validate add-remote-access-ebpf-recording --strict`.
