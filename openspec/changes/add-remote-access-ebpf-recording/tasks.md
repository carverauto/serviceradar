## 1. Design and Licensing
- [ ] 1.1 Review candidate Go eBPF loader dependencies for license, maintenance, Bazel compatibility, and kernel support.
- [ ] 1.2 Decide the shared `serviceradar-agent` eBPF runtime/loader boundary, with `github.com/cilium/ebpf` as the leading candidate unless review finds a blocker.
- [ ] 1.3 Record exact Teleport v14 files consulted, if any, with tag, commit, headers, and dependency scan results.
- [ ] 1.4 Define the session scoping mechanism for SSH and provider-console adapters, preferring cgroup-scoped monitoring.

## 2. Agent Collector
- [ ] 2.1 Add Linux-only BPF build plumbing and keep non-BPF builds working by default.
- [ ] 2.2 Implement the shared agent BPF runtime pieces needed by remote-access recording without making them remote-access-specific.
- [ ] 2.3 Implement command exec probes and user-space normalization.
- [ ] 2.4 Implement file open/access probes and user-space normalization.
- [ ] 2.5 Implement network connect probes and user-space normalization.
- [ ] 2.6 Implement loss counters for kernel drops, parser failures, and user-space backpressure.
- [ ] 2.7 Bind collector lifecycle to remote-access session open/close/timeout paths.

## 3. Policy and Capabilities
- [ ] 3.1 Make `remote_access.bpf` advertise only after build, kernel, permission, and startup checks pass.
- [ ] 3.2 Preserve fail-closed behavior when policy requires BPF and the collector cannot start.
- [ ] 3.3 Preserve explicit procfs fallback behavior only when policy allows fallback.
- [ ] 3.4 Ensure enhanced events never include private keys, passwords, terminal input bytes, or file contents.

## 4. Validation
- [ ] 4.1 Add unit tests for capability checks, policy gates, redaction, normalization, and loss counters.
- [ ] 4.2 Add Linux integration tests behind explicit build tags or environment gates.
- [ ] 4.3 Add a remote-access eBPF smoke script that proves command, file, network, and loss event correlation.
- [ ] 4.4 Run `go test ./go/pkg/agent/remoteaccess` and a BPF-enabled focused test on a compatible Linux host.
- [ ] 4.5 Run `openspec validate add-remote-access-ebpf-recording --strict`.
