# rules_aya_ebpf

Build a Rust [aya](https://aya-rs.dev) eBPF program under Bazel, from declared
inputs only — no host `cargo`, no host `bpf-linker`, no network. That is what
makes it work identically on a laptop, in CI, and on remote execution.

## MODULE.bazel

Register rules_aya_ebpf in your MODULE.bazel as follows:

```python
bazel_dep(name = "rules_aya_ebpf", version = "0.1.0")
git_override(
    module_name = "rules_aya_ebpf",
    commit = "<sha>",
    remote = "https://github.com/marvin-hansen/rules_aya_ebpf.git",
)
```

`archive_override` against a tagged release tarball works too, and is worth
preferring in CI: pin `integrity`, and list a mirror URL ahead of the GitHub one.

## Updating the ruleset

Bump the `commit` (or the URL + `integrity`, or the version if you consume it from
a registry), then refresh the lockfile:

```sh
bazel mod deps --lockfile_mode=update
```

Provided you pinned the toolchain as described under [Pinning and bumping](#pinning-and-bumping),
the nightly, `bpf-linker` and your vendor tree stay exactly where you pinned them.

## ebpf_object

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

`vendor` must be declared in the package that *is* the vendor root — that
package's path is what cargo receives as `[source.vendored-sources] directory`.

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

**Pin explicitly in your root module. Do not inherit the defaults.**

```python
aya_ebpf = use_extension("@rules_aya_ebpf//bzlmod:extensions.bzl", "aya_ebpf")
aya_ebpf.nightly(date = "...", rustc_sha256 = "...", ...)
aya_ebpf.bpf_linker(version = "...", sha256 = "...", archive_extension = "...")
```

The defaults in `bzlmod/extensions.bzl` are a working example and a starting point,
not something to depend on. The reason is the vendor tree: `-Z build-std` resolves
the std workspace's own crates.io dependencies, so **your vendor tree is a function
of this ruleset's nightly**. If you inherit the default, one half of that pair lives
in this repository and the other half in yours — and a release here invalidates
your vendor tree from the outside.

Pin in your root module and the pair lives in one repository and moves in one
commit. The failure mode is at least loud (`cargo --offline --locked` aborts on a
missing vendored crate) but it should not be reachable at all.

### Regenerating the vendor tree

**Vendoring and the nightly pin always move together.**

```sh
cargo vendor --sync <rust-src>/library/Cargo.toml <vendor-dir>
```

Run it from the crate directory, which requires the `[workspace]` table described
under [Cargo interoperability](#cargo-interoperability). One caveat: **`cargo
vendor` manages its destination**, so pointed straight at your vendor directory it
deletes that package's `BUILD.bazel`. Vendor to a temporary directory and swap the
contents in.

Expect a large diff for a small change: `cargo vendor` omits the version from a
crate's directory name when only one version is in the graph, so a crate that
moved version appears as hundreds of modified files rather than an add plus a
delete.

### LLVM must match

bpf-linker consumes the bitcode rustc emits, and LLVM bitcode is backward- but
**not** forward-compatible, so rustc's LLVM must be no newer than bpf-linker's.
Check both before picking a date:

```sh
rustc +nightly-<DATE> --version --verbose | grep LLVM    # rustc's LLVM
strings <bpf-linker> | grep -oE 'LLVM [0-9.]+' | sort -u # the linker's
```

At the time of writing bpf-linker 0.10.4 bundles LLVM 22.1.7, and
rust-lang/rust#158734 moved rustc to LLVM 23 on 2026-08-05 — so
`nightly-2026-08-05` (LLVM 22.1.8) is the newest usable nightly, and the pin sits
deliberately on that boundary.

## Cargo interoperability

**Declare an empty `[workspace]` table in your eBPF crate's `Cargo.toml`:**

```toml
[workspace]

[dependencies]
aya-ebpf = "0.1.1"
```

The crate has to resolve on its own — it builds for `bpfel-unknown-none` with
`-Z build-std` on a pinned nightly, which has nothing in common with how an
enclosing workspace builds. Listing it in the parent's `workspace.exclude` is
**not** sufficient: cargo still refuses with `current package believes it's in a
workspace when it's not`. The table is what makes `cargo vendor`, `cargo check`
and `cargo tree` work in that directory.

The rule detects the table and leaves your manifest alone. Without it, the rule
appends the same table to its **staged copy**, so the build works either way —
you simply lose the ability to run cargo there by hand.

Either way, **the eBPF crate is invisible to workspace-wide cargo commands**:
`cargo check --workspace` does not compile it, and its dependency versions are not
governed by the workspace's `[workspace.dependencies]`. Bazel is the only thing
that builds it, so treat a green workspace `cargo check` as saying nothing about
this crate.

## Relationship to rules_rust

This ruleset does not depend on rules_rust, and its toolchain
type (`@rules_aya_ebpf//:toolchain_type`) is distinct from
`@rules_rust//rust:toolchain_type`, so registering it cannot perturb the stable
Rust toolchain your other targets resolve. The two coexist without interacting.

Likewise, the vendor tree this rule consumes is separate from any `crates_vendor`
output rules_rust uses. Keep it outside that directory: a regeneration script that
wipes and rebuilds the crate-universe tree will take your eBPF vendor with it.

## Not a `rust_binary`

This deliberately drives `cargo` rather than going through rules_rust. A pure
`rust_binary` with a `bpfel-unknown-none` platform transition is the better
end-state, but rules_rust's `-Zbuild-std` support is experimental and untested
for tier-3 `no_std` targets. This encodes the upstream-supported aya flow, which
is known to produce a correct object, and makes its *inputs* hermetic — which was
the actual problem.
