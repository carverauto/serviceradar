# rules_aya_ebpf

Build a Rust [aya](https://aya-rs.dev) eBPF program under Bazel, from declared
inputs only — no host `cargo`, no host `bpf-linker`, no network. That is what
makes it work identically on a laptop, in CI, and on remote execution.

```python
load("@rules_aya_ebpf//:ebpf_object.bzl", "ebpf_object")

ebpf_object(
    name = "my_probe_object",
    bin_name = "my-probe",
    manifest = "Cargo.toml",
    srcs = glob(["src/**/*.rs"]) + ["Cargo.lock"],
    vendor = "//third_party/my_probe_vendor:vendor_srcs",
    out = "my_probe.o",
)
```

## Why?

Compiling an aya program is not a normal `rust_binary`. It needs a **nightly**
rustc (`-Z build-std` is nightly-only), the **`rust-src`** component (the
`bpfel-unknown-none` target is tier 3 and ships no precompiled `core`, so
build-std compiles it from source), and **`bpf-linker`**, an LLVM-based linker
that emits BPF bytecode plus BTF. None of that should perturb the stable Rust
toolchain the rest of a repository uses, and all of it has to be selected for
whichever machine runs the action.

That is exactly what Bazel toolchain resolution is for, so the pins live behind
`@rules_aya_ebpf//:toolchain_type` and a consumer never names them.

## Execution platform vs. target platform

An eBPF object is a Linux kernel artifact — eBPF is a Linux facility, and the
object is loaded by a Linux verifier. But **building** one is cross-compilation
to `bpfel-unknown-none`, and does not itself require Linux.

The toolchain therefore constrains the **execution** platform (where rustc and
bpf-linker run) and says nothing about the target platform. Only `linux_x86_64`
is registered today; upstream publishes darwin builds of every input, so adding
macOS is a row in `_EXEC_PLATFORMS` plus its sha256s — no rule changes.

If no toolchain matches, the rule fails with an explanation rather than Bazel's
bare "no matching toolchains found".

Mark the *target* Linux-only where you instantiate the rule, if that is true of
your consumers:

```python
ebpf_object(
    name = "my_probe_object",
    target_compatible_with = ["@platforms//os:linux"],
    ...
)
```

## Pinning and bumping

Pins live in `bzlmod/extensions.bzl` and are overridable from the root module:

```python
aya_ebpf = use_extension("@rules_aya_ebpf//bzlmod:extensions.bzl", "aya_ebpf")
aya_ebpf.nightly(date = "...", rustc_sha256 = "...", ...)
aya_ebpf.bpf_linker(version = "...", sha256 = "...")
```

**A nightly bump is not a one-line change**, for two reasons.

*The vendor tree moves with it.* `-Z build-std` resolves the whole sysroot, so the
std workspace's own crates.io dependencies are vendored alongside your program's
and change whenever the nightly does. Regenerate against the matching `rust-src`:

```sh
cargo vendor --sync <rust-src>/library/Cargo.toml
```

Vendoring and the nightly pin always move together.

*LLVM is the real ceiling.* bpf-linker consumes the bitcode rustc
emits, and LLVM bitcode is backward- but **not** forward-compatible, so rustc's
LLVM must be no newer than bpf-linker's. Check both before picking a date:

```sh
rustc +nightly-<DATE> --version --verbose | grep LLVM   # rustc's LLVM
strings <bpf-linker> | grep -oE 'LLVM [0-9.]+' | sort -u # the linker's
```

At the time of writing bpf-linker 0.10.4 bundles LLVM 22.1.7, and
rust-lang/rust#158734 moved rustc to LLVM 23 on 2026-08-05 — so
`nightly-2026-08-05` (LLVM 22.1.8) is the newest usable nightly, and the pin sits
deliberately on that boundary. Going further needs an LLVM 23 bpf-linker
upstream, not a change here. A mismatch shows up as a link failure, so it fails
loudly rather than producing a bad object.

## Not a `rust_binary`

This deliberately drives `cargo` rather than going through rules_rust. A pure
`rust_binary` with a `bpfel-unknown-none` platform transition is the better
end-state, but rules_rust's `-Zbuild-std` support is experimental and untested
for tier-3 `no_std` targets. This encodes the upstream-supported aya flow, which
is known to produce a correct object, and makes its *inputs* hermetic — which was
the actual problem.
