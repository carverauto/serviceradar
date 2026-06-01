# Change: Hermetic Bazel build for the netprobe eBPF object

## Why

The netprobe native add-on ships `netprobe_ebpf.o` (an aya-ebpf program, loaded at
runtime) as a bundle data entry, so the object MUST be produced during the
`bazel build` of the add-on bundle. Today `//rust/netprobe/ebpf:netprobe_ebpf_object`
is a `genrule` that shells out to a **host** `cargo +nightly -Z build-std=core
--target bpfel-unknown-none` plus a host `bpf-linker` (`rust/netprobe/ebpf/build-ebpf-object.sh`).
This is non-hermetic and breaks the publish pipeline:

- The genrule carries no `local`/`no-remote` tag, so under `--remote_executor`
  (the publish lane, `.bazelrc.remote`) it dispatches to a BuildBuddy RBE worker
  that has no Rust toolchain and dies at `command -v cargo`.
- Even forced local, the `forgejo-ci` publish image has **no** cargo / rustc /
  rustup / bpf-linker / clang / llvm (verified), and runs non-root, so the
  toolchain cannot be installed at runtime.
- The only lane that builds the object is the gated `netprobe-kernel-*` verifier
  on dedicated runners — so the object has never built in a standard-RBE lane.

Net effect: the native add-on publish (`Publish Native Add-ons` →
`push_all_native_addons.sh`) **cannot produce the netprobe bundle**, which blocks
the netprobe eBPF netflow→process capture end-to-end test. This change makes the
eBPF object build hermetic so it builds anywhere — local, CI, and RBE — from
Bazel-declared toolchain inputs only.

## What Changes

- Register a **pinned nightly Rust toolchain with `rust-src`** as a Bazel-managed
  input (for `-Z build-std=core`), without disturbing the existing stable `1.93.0`
  toolchain used by all other Rust targets.
- Provide **`bpf-linker` hermetically** as a Bazel input (the hardest sub-problem;
  approach decided by a spike — see `design.md`).
- Add a `bpfel-unknown-none` target triple / eBPF platform and a Bazel rule that
  builds `netprobe_ebpf.o` from the hermetic toolchain + linker, replacing the
  host-`cargo` `genrule`. The action declares all tools as inputs and does **not**
  read the system `PATH`, so it is RBE-correct.
- Keep the produced object byte-for-byte loadable by the existing aya userspace
  loader (`--ebpf-object` / `SERVICERADAR_NETPROBE_EBPF_OBJECT`) and keep the
  `netprobe-kernel-*` verifier lane green.
- Remove the host-toolchain `build-ebpf-object.sh` PATH-probing fallback once the
  hermetic path is the single source of truth.

## Impact

- Affected specs: `netprobe-ebpf-builds` (new capability).
- Affected code:
  - `rust/netprobe/ebpf/BUILD.bazel`, `rust/netprobe/ebpf/build-ebpf-object.sh`
  - `MODULE.bazel` (nightly toolchain + rust-src + bpf-linker repos)
  - `build/platforms/BUILD.bazel`, `build/rust/BUILD.bazel`, `build/toolchains/`
    (eBPF platform/constraint + toolchain wiring)
  - `scripts/ci/netprobe-ebpf-verify.sh` (drops the host-toolchain assumption)
  - Unblocks `.forgejo/workflows/native-addons.yml` (`push_all_native_addons.sh`).
- Related (not modified here): `add-hermetic-native-addon-builds` is Go-gate /
  tool-pinning focused and does **not** cover the Rust eBPF toolchain; this is a
  sibling change.
- Out of scope (follow-up): multi-arch eBPF (`--cfg bpf_target_arch` is currently
  hardcoded `x86_64`); the amd64 object is the e2e target and is correct.
