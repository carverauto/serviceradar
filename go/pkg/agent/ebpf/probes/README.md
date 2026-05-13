# Agent eBPF Probes

This package contains ServiceRadar-owned eBPF probe source and checked-in
`bpf2go` outputs. Normal Go, Bazel, and container builds consume the generated
`.go` and `.o` artifacts directly and do not require a local clang/LLVM
installation.

Current probe groups:

- `selftest`: minimal load/attach validation program.
- `command`: execve command observation event contract.
- `file`: open/access observation event contract.
- `network`: connect syscall observation event contract.

Regenerate artifacts after editing `src/*.bpf.c`:

```bash
scripts/generate-agent-ebpf.sh
```

Verify that checked-in artifacts are current:

```bash
scripts/generate-agent-ebpf.sh --check
```

Probe source must carry explicit SPDX headers. User-space loader code remains
under the project Apache-2.0 license. BPF program license strings may use a
kernel-compatible dual license when helpers require it.
