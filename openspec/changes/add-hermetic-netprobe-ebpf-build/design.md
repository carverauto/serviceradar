## Context

`rust/netprobe/ebpf` is an **aya-ebpf 0.1.1** program (`#![no_std] #![no_main]`,
panic-loop handler, `[[bin]] netprobe-ebpf`). Building it requires:

- **nightly** rustc (the `-Z build-std=core` flag is nightly-only),
- the **`rust-src`** component (build-std compiles `core` from source for the
  tier-3 `bpfel-unknown-none` target, which ships no precompiled std),
- **`bpf-linker`** as the linker for `bpfel-unknown-none` (an LLVM-based linker
  that emits BPF bytecode + BTF), invoked via
  `CARGO_TARGET_BPFEL_UNKNOWN_NONE_LINKER`,
- `RUSTFLAGS="--cfg bpf_target_arch=\"x86_64\" -C link-arg=--btf"`.

Current state (verified):
- `MODULE.bazel` registers rules_rust **0.65.0** with only **stable 1.93.0**
  (`extra_target_triples` = linux gnu/musl only). No nightly, no `bpfel-unknown-none`,
  no build-std, no eBPF platform/constraint anywhere in `build/`.
- `rust/netprobe/build.rs` can build the object via
  `aya_build::build_ebpf([...], Toolchain::Nightly)` but only when
  `SERVICERADAR_NETPROBE_BUILD_EBPF` is set; the Bazel `cargo_build_script` does
  not set it. The live path is the `genrule` + `build-ebpf-object.sh` host shell.
- The `forgejo-ci` publish image has zero Rust/LLVM tooling and runs non-root.

## Goals / Non-Goals

- **Goals**
  - Build `netprobe_ebpf.o` from Bazel-declared inputs only — no system `PATH`,
    no host cargo/bpf-linker — so it builds local, in CI, and on **RBE**.
  - Do not perturb the stable `1.93.0` toolchain that every other Rust target uses.
  - Keep the object loadable by the existing aya userspace loader and keep the
    `netprobe-kernel-*` verifier lane green.
  - Unblock `push_all_native_addons.sh` (the netprobe publish) on RBE.
- **Non-Goals**
  - Multi-arch eBPF. `--cfg bpf_target_arch` stays `x86_64` for v1 (amd64 is the
    e2e target); a follow-up handles arm64. CO-RE/BTF already absorbs most kernel
    struct deltas at load time.
  - Migrating the userspace netprobe crate or other Rust targets to nightly.
  - Folding into `add-hermetic-native-addon-builds` (Go-gate scope).

## Decisions

### Decision 1 — Keep aya's nightly+build-std flow; make its **inputs** hermetic (not a pure `rust_binary`)

Two ways to build aya eBPF under Bazel:

- **H1 — pure rules_rust `rust_binary` + build-std + `bpfel-unknown-none`
  platform transition.** Rejected as the primary path: rules_rust 0.65's
  `-Zbuild-std` support is experimental and not exercised for a **tier-3 no_std**
  target; wiring `core`-from-source through rules_rust's toolchain for `bpfel`
  is high-risk and likely needs patching rules_rust. Revisit later as the
  end-state once upstream support matures.
- **H2 (CHOSEN) — a hermetic toolchain repo set feeding a sandboxed cargo/aya
  build action.** Provide pinned nightly `cargo`/`rustc`, the `rust-src` sources,
  and `bpf-linker` as Bazel external repos; rewrite the eBPF build as a `genrule`
  (or a small custom rule) whose `tools`/`srcs` include those binaries+sources and
  whose `cmd` sets `PATH`/`CARGO_HOME`/`RUSTUP_*`/linker env **only** from runfiles
  (`use_default_shell_env` off). This preserves the upstream-supported aya build
  flow we know produces a correct object, while making every input a declared
  Bazel artifact — which is exactly what makes it RBE-correct.

Rationale: the failure we are fixing is *non-hermetic inputs on RBE*, not the
build recipe. H2 fixes precisely that with the least risk; H1 rewrites a working
recipe against immature rules_rust surface.

### Decision 2 — Pin the nightly toolchain via rustup-dist `http_archive`s (rules_rust-independent)

Rather than register a nightly through rules_rust's `rust` extension (whose
nightly + `rust-src` + `-Zbuild-std`-for-tier-3 surface is the exact immature area
H1 was rejected over), fetch the rustup-dist nightly components directly as
`http_archive`s pinned by sha256, and assemble a sysroot inside the action by
running each component's `install.sh` into a scratch prefix. This is fully
transparent, leaves the stable `1.93.0` rules_rust toolchain (and every other Rust
target) completely untouched, and the assembled `cargo`/`rustc`/`rust-src` become
declared action inputs. **Pinned (nightly `2026-05-31`, validated on the box):**
- `rustc-nightly-x86_64-unknown-linux-gnu.tar.xz` sha256 `9e6ac5e3…89bf4`
- `cargo-nightly-x86_64-unknown-linux-gnu.tar.xz` sha256 `45c7eca0…ffa8`
- `rust-std-nightly-x86_64-unknown-linux-gnu.tar.xz` sha256 `9ff25d51…d829` (host std for proc-macros like aya-ebpf-macros)
- `rust-src-nightly.tar.xz` sha256 `921bc11d…9ff9` (sources for `-Z build-std=core`)

(All from `https://static.rust-lang.org/dist/2026-05-31/`. The exec platform —
RBE worker / forgejo-ci container — is linux-x86_64-gnu, matching these.)

### Decision 5 — Vendor the eBPF crate dependencies for an offline build

`cargo build` for the eBPF crate resolves `aya-ebpf` (+ transitive) from crates.io.
RBE action sandboxes have **no network**, so the build must be offline. We vendor
the deps and point the action's cargo at them via a generated `.cargo/config.toml`
(`[source.crates-io] replace-with`).

Two important details settled during implementation:
- **`-Z build-std` also needs the std workspace's crates.io deps** (e.g.
  `rustc-literal-escaper`, `compiler_builtins`, `libc`, `object`, `hashbrown`),
  because build-std resolves the whole sysroot. So the vendor is produced with
  `cargo vendor --sync <nightly rust-src>/library/Cargo.toml` against the matching
  nightly — 56 crates total. Re-vendoring is coupled to the nightly pin.
- **Committed as the extracted `rust/netprobe/ebpf/vendor/` tree** (56 crates,
  ~29 MB), consumed directly by the build script via `--vendor`. (A compressed
  single-tarball variant was tried but rejected in favor of the transparent,
  diffable extracted tree.) Fully hermetic — committed input, no network.

### Decision 3 — `bpf-linker` from the UPSTREAM prebuilt static-musl release (spike RESOLVED 2026-06-01)

`bpf-linker` links against LLVM via `llvm-sys`. The spike (Task 1) found that
**aya-rs/bpf-linker publishes upstream prebuilt release binaries**, including a
**fully-static `x86_64-unknown-linux-musl`** build that statically bundles LLVM
(the installed `0.10.3` binary shows no dynamic LLVM via `ldd`). This is the
cleanest hermetic input: an upstream, sha256-pinned, self-contained static binary
that runs on any linux exec platform (including RBE) — no `toolchains_llvm`, no
`crate_universe` LLVM build, no self-hosted blob.

Candidates considered and rejected:
- *rustc-bundled LLVM* — N/A: `0.10.3` statically links its OWN LLVM, not rustc's.
- *Hermetic LLVM + crate_universe build* — unnecessary given the upstream static
  binary; would add a heavy LLVM toolchain for no benefit.

**Resolved pins (all empirically validated):**
- **Rust nightly: `nightly/2026-05-31`** (rustc `1.98.0-nightly (14210df0e)`).
  Proven on the test box: this nightly + `rust-src` + bpf-linker `0.10.3` produced
  a valid `ELF 64-bit LSB relocatable, eBPF` object (79,952 bytes) for the netprobe
  programs. rules_rust registers it via `versions = ["nightly/2026-05-31"]`.
- **bpf-linker: `v0.10.3`**, asset `bpf-linker-x86_64-unknown-linux-musl.tar.gz`,
  `sha256:0fa4645d2dfbb5cafe6231b0aa9fad4f1430bd0871e3bd7319e82d827bf6262c`
  (from `https://github.com/aya-rs/bpf-linker/releases/tag/v0.10.3`). arm64 musl
  (`sha256:02f71967eddf61229fd0ae39736bfcaa00b27872df5af868b025f578371204d1`) is
  available for the multi-arch follow-up.
- **rust-src: `rust-src-nightly` for 2026-05-31** (arch-independent source),
  injected into the nightly sysroot so `-Z build-std=core` finds
  `lib/rustlib/src/rust/library/core`. (sha256 pinned during Task 2 wiring.)

### Decision 4 — eBPF platform/constraint + verifier reuse

Add an `bpfel-unknown-none` target triple to the nightly toolchain config and a
minimal eBPF platform/constraint under `build/platforms` only if needed for
toolchain resolution; the H2 action can also pass `--target bpfel-unknown-none`
directly to the hermetic cargo without a full Bazel platform transition. Keep
`scripts/ci/netprobe-ebpf-verify.sh` building the same Bazel target (it stops
needing host nightly), so the kernel-matrix verifier continues to gate the object.

### Decision 6 — Package the whole thing as a ruleset with a real toolchain (`//third_party/rules_aya_ebpf`)

Decisions 1–5 got the object building hermetically, but left the *mechanism*
spread across three places that had no business knowing about each other: five
`http_archive`s in the root `MODULE.bazel` (53 lines), a 110-line
`build-ebpf-object.sh`, and a `genrule` wiring them together. Three problems with
that shape, none of them cosmetic:

- **The Linux constraint was on the wrong axis.** The genrule carried
  `target_compatible_with = ["@platforms//os:linux"]`, which says "this artifact
  is for Linux". The actual constraint is that the *component tarballs are
  linux-x86_64 binaries* — a statement about the execution platform, and one that
  never mentioned x86_64 at all. Toolchain resolution is Bazel's mechanism for
  exactly this, and getting the axis right is what makes the arm64 follow-up
  (6.1) a second `toolchain()` registration instead of a genrule edit.
- **A shell script is a hole in the graph** (see the repo-wide hard rule). Its
  inputs were `$(location ...)` strings interpolated into a `cmd`, so nothing
  type-checked them.
- **None of it is netprobe-specific.** Pinned nightly + `rust-src` + `bpf-linker`
  + `-Z build-std=core` for `bpfel-unknown-none` is simply *how you build an aya
  program under Bazel*.

So it is now `//third_party/rules_aya_ebpf`: a vendored Bazel module (alongside
`rules_erlang` / `rules_elixir`, and listed in `//.bazelignore` the same way) with
`toolchain_type`, an `aya_ebpf_toolchain` rule, an `ebpf_object` rule that
generates its action inline, and a module extension that fetches the pins and
declares the toolchains. The root `MODULE.bazel` keeps a `bazel_dep` +
`local_path_override` and nothing else; the pins are overridable from the root via
the extension's `nightly` / `bpf_linker` tag classes.

`exec_compatible_with = [linux, x86_64]` sits on the `toolchain()`; the
Linux-only-ness of the *artifact* stays on the target. Verified: a darwin
execution platform is rejected by constraint, a darwin target platform skips the
target, and an unresolved toolchain fails with an authored explanation rather than
Bazel's bare "no matching toolchains found".

**The object is byte-identical across the refactor** — sha256
`4b0addd0526ea358ecf4134321c79788683d710e77fc875990686b6612d69995`, 63,160 bytes,
before and after, and the same bytes inside the add-on bundle. The recipe did not
change; only who owns it.

Naming: `rules_aya_ebpf`, not `rules_netprobe_ebpf`, because the eventual home is
its own repository and nothing in it is about netprobe. The crate directory and
vendor tree are rule *attributes* for the same reason — the ruleset must never
name `//rust/netprobe/...`.

## Risks / Trade-offs

- **bpf-linker ↔ LLVM coupling** → Decision 3 spike; pin both and document.
- **nightly date drift / aya version coupling** → pin the nightly date + aya
  versions together; CI rebuilds the object so drift surfaces immediately.
- **RBE worker exec platform** is linux-amd64 → fetch linux-amd64 nightly +
  bpf-linker for the exec platform; the bpfel **output** is host-arch-independent
  bytecode (modulo the `bpf_target_arch` cfg, a documented non-goal here).
- **Toolchain download size** on cold RBE/CI → mitigated by the existing Bazel
  repo/disk cache steps already in the workflows.
- **Reproducibility** — the object must be deterministic so the kernel-verifier
  and the published bundle agree; pin every input by version+sha256.

## Migration Plan

1. Land hermetic toolchain repos + the rewritten eBPF action behind the same
   target label (`//rust/netprobe/ebpf:netprobe_ebpf_object`) so all consumers
   (bundle, verifier) are unchanged.
2. Verify byte-identical / loadable object on the `netprobe-kernel-*` verifier.
3. Confirm `bazel build //build/native_addons:netprobe_addon_bundle_push` succeeds
   on RBE (the lane that currently fails).
4. Remove `build-ebpf-object.sh` host-PATH probing; the script (if kept) only
   wraps the hermetic target.
5. Re-dispatch `Publish Native Add-ons`; confirm the `sha-<HEAD>` release + index.

Rollback: the change is isolated to the eBPF target + toolchain repos; reverting
the commit restores the prior genrule (publish stays blocked, status quo ante).

## Open Questions

- ~~Which bpf-linker hermeticity approach wins the spike?~~ RESOLVED: upstream
  prebuilt static-musl binary (Decision 3).
- ~~Exact nightly date?~~ RESOLVED: `nightly/2026-05-31` (validated on the box).
- **rust-src into the sysroot**: confirm whether to (a) let rules_rust's nightly
  toolchain provide `rust-src` directly, or (b) fetch the `rust-src-nightly`
  tarball via `http_archive` and symlink `library/` into the toolchain sysroot in
  the action. Lean (b) for explicit control if rules_rust 0.65 doesn't expose it.
- Do we need a real Bazel `bpfel` platform/transition, or is `--target` on the
  hermetic cargo sufficient for the H2 action? (Lean: `--target` is sufficient —
  the action invokes the nightly cargo directly with `--target bpfel-unknown-none`.)
