## ADDED Requirements

### Requirement: Hermetic eBPF object build
The netprobe eBPF object SHALL be built entirely from Bazel-declared toolchain
inputs — a pinned nightly Rust toolchain, the `rust-src` sources for
`-Z build-std=core`, and a hermetically provided `bpf-linker` — and SHALL NOT
depend on any tool discovered via the system `PATH` (no host `cargo`, `rustc`,
`rustup`, or `bpf-linker`). The build target is
`//rust/netprobe/ebpf:netprobe_ebpf_object` (output `netprobe_ebpf.o`). Every
external input SHALL be pinned by version and `sha256`.

#### Scenario: Build with no host Rust toolchain
- **WHEN** `bazel build //rust/netprobe/ebpf:netprobe_ebpf_object` runs in an
  environment with no `cargo`/`rustc`/`rustup`/`bpf-linker` on `PATH`
- **THEN** the build succeeds and produces `netprobe_ebpf.o`
- **AND** it uses only the Bazel-provided nightly toolchain, `rust-src`, and
  `bpf-linker` inputs

#### Scenario: Builds on remote execution
- **WHEN** the object is built with `--remote_executor` (the publish lane) on a
  BuildBuddy RBE worker that has no preinstalled Rust toolchain
- **THEN** the action resolves all tools from its declared inputs and completes
  successfully (it does not fail at `command -v cargo`)

### Requirement: Stable toolchain is not disturbed
Introducing the nightly toolchain for the eBPF object SHALL NOT change the default
Rust toolchain (stable `1.93.0`) used by all other Rust targets in the repository.
The eBPF action SHALL select the nightly toolchain explicitly.

#### Scenario: Other Rust targets keep building on stable
- **WHEN** any non-eBPF Rust target (e.g. `//rust/netprobe:netprobe`) is built
- **THEN** it continues to use the registered stable `1.93.0` toolchain
- **AND** its build outputs are unchanged by the addition of the nightly toolchain

### Requirement: eBPF object remains loadable and gate-verified
The hermetically built object SHALL be byte-compatible with the existing aya
userspace loader (consumed at runtime via `--ebpf-object` /
`SERVICERADAR_NETPROBE_EBPF_OBJECT`) and SHALL keep the `netprobe-kernel-*`
verifier lane passing on supported kernels.

#### Scenario: Kernel verifier accepts the hermetic object
- **WHEN** the `netprobe-kernel-*` verifier runs against the hermetically built
  object on Linux 5.8, 5.15, and 6.x
- **THEN** the object loads and attaches successfully
- **AND** on Linux 5.4 the loader still refuses (kernel-too-old) as before

### Requirement: Netprobe add-on bundle includes the eBPF object
The native add-on publish SHALL build successfully on remote execution, and the
resulting netprobe bundle SHALL contain `netprobe_ebpf.o` as a data entry. This
covers `//build/native_addons:netprobe_addon_bundle_push` as driven by
`push_all_native_addons.sh` in the `Publish Native Add-ons` workflow.

#### Scenario: Publish lane produces a complete netprobe bundle
- **WHEN** the `Publish Native Add-ons` workflow builds the netprobe bundle on RBE
- **THEN** the bundle build succeeds
- **AND** the produced per-arch tarball contains `netprobe_ebpf.o`
