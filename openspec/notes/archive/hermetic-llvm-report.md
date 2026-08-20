# Can ServiceRadar's from-source C builds survive a sysroot-less toolchain?

**A hermetic-llvm feasibility report**

| | |
|---|---|
| Date | 2026-08-10 |
| Branch | `experiment/hermetic-llvm` |
| Base | `no-clang` @ `0b89f4d` |
| Dependency | hermetic-llvm 0.8.17 (BCR module name: `llvm`), LLVM 22.1.8 |
| Runs | 6, on BuildBuddy RBE |

A scoped feasibility test of [hermetic-llvm](https://github.com/hermeticbuild/hermetic-llvm) against the two
things most likely to break: OpenSSL and libpq compiled from source, and the statically linked musl netprobe
binaries.

| Run | Subject | Toolchain | Result |
|---|---|---|---|
| 1 | openssl-sys + pq-sys | gcc (baseline) | PASS |
| 2 | openssl-sys + pq-sys | hermetic-llvm | **FAIL** |
| 3 | openssl-sys + pq-sys | hermetic-llvm + patch | PASS |
| 4 | openssl-sys + pq-sys | gcc + patch (regression) | PASS |
| 5 | musl netprobe | gcc (baseline) | PASS |
| 6 | musl netprobe | hermetic-llvm | PASS |

---

## Verdict: both lift in

**Yes — with one patch.** OpenSSL and libpq build from source under a zero-sysroot clang toolchain after a
five-line addition to a patch ServiceRadar already maintains. The musl netprobe binaries build and pass their
static-linkage assertions with **no** patch at all.

The single blocker was shallow and of a kind already handled in this repo. Nothing structural resisted.

This does not clear the whole migration. It clears the part that was most likely to be a dead end, which is
what the experiment was for.

---

## Motivation: the compiler is pinned to an image nobody updates

Today the C/C++ toolchain is whatever `rbe-executor:v1.0.24.3` happens to contain. That tag is pinned in three
places (`../../../MODULE.bazel`, and twice in `../../../build/platforms/BUILD.bazel`), so a compiler bump means an image rebuild,
a republish, a three-site edit, and a cold cache for everyone.

The sharper problem is that *nothing verifies the image matches the declaration.* The toolchain names builtin
include directories for Oracle Linux gcc-toolset-13, Debian bullseye GCC 10, Ubuntu GCC 11, Fedora GCC 11, and
GCC 5 "for older remote workers" — a museum of executor images that no longer exist. Bazel will not tell you
which of those paths are dead: a stale one is silently ignored, a missing live one surfaces as a confusing
header error far from its cause.

A second unenforced contract sits in `../../../BUILD.md`, which asks Linux developers to install `musl-tools`,
`x86_64-linux-musl-gcc`, and `clang-18` by hand.

A hermetic toolchain turns both contracts into a version string in `../../../MODULE.bazel` that Bazel actually enforces,
and makes the compiler identical on a laptop and an executor.

---

## Experiment 1 — openssl-src and pq-src

These were tested first because they are the least Bazel-native thing in the tree: their build scripts shell out
to perl and make, probe the compiler, and generally assume glibc headers exist at `/usr/include`. If anything
was going to reject a sysroot-less toolchain, it was these.

`pq-sys` depends on `openssl-sys` through `pq-src`, so it is a downstream consumer rather than an independent
data point — but it does link the result.

### The failure

Run 2 died at 11s, inside OpenSSL's `Configure`:

```
target already defined - linux-x86_64 (offending arg: x86_64-linux-gnu)
Failure!  build file wasn't produced.
openssl-src: failed to build OpenSSL from source
```

A clang toolchain emits the **separated** `-target x86_64-linux-gnu` form. OpenSSL's `Configure` has no
`-target` flag and takes its target as a positional argument, so it read the bare triple as a second target
name. GCC never emitted that form, which is why this had never surfaced.

### The fix

This is the same class as the `-no-canonical-prefixes` problem already patched in this repo, and it goes in the
same function, reusing openssl-src's own `skip_next` mechanism:

```rust
// third_party/rust_patches/openssl_src_runfiles_patch
if arg == "-target" {
    skip_next = true;
    continue;
}
```

Dropping the pair loses nothing: the same command line also carries `--target=x86_64-unknown-linux-gnu`, which
`Configure` parses correctly.

The patch was applied to both the vendored `src/lib.rs` and the patch file, per the convention in
`../../../scripts/vendor.sh`, then round-trip verified — reverse-apply followed by forward-apply reproduces the vendored
tree byte-for-byte, so `apply_vendor_patch` will land it on a fresh vendor.

### Results

| Run | Toolchain | Wall | Outcome |
|---|---|---|---|
| 1 baseline | gcc (buildbuddy) | 5.7s | pass — fully cached, proves only "built at some point" |
| 2 | hermetic-llvm | 211s | **FAIL** — Configure |
| 3 | hermetic-llvm + patch | 229s | **PASS** — OpenSSL + libpq compiled from source |
| 4 regression | gcc + patch | 236s | **PASS** — real rebuild, critical path 235s |

Run 4 matters as much as run 3. The patch re-keyed the action, so the openssl build script genuinely re-ran
under GCC rather than replaying a cache entry. The `-target` filter being a no-op for GCC is now measured, not
argued.

---

## Experiment 2 — musl netprobe

This is the workaround-heavy corner: statically linked netprobe binaries for x86_64 and aarch64 musl, guarded by
`//rust/netprobe:static_linkage_test`, which parses both ELFs and asserts no `PT_INTERP`, no `DT_NEEDED` entries,
and no libpcap in any dynamic tag.

hermetic-llvm has no musl *toolchain* — libc comes from the target platform — so the two musl platforms gained
`@llvm//constraints/libc:musl` and `@llvm//constraints/pie:off` (rustc forces `-no-pie` on musl). A control run
confirmed those constraints are inert: no toolchain registered in `../../../MODULE.bazel` constrains on them, and the gcc
musl build was unchanged.

| Run | Config | Actions | Outcome |
|---|---|---|---|
| 5 baseline | gcc musl | 51 | PASS |
| 5b control | gcc musl + new constraints | 51 | PASS — constraints inert |
| 6 | hermetic-llvm musl | 5,308 | PASS — 350s, no patch |

### Proof it was really clang

Artifacts stay in the CAS under `--remote_download_minimal`, so there was nothing local to hash. Toolchain
resolution answers it directly and better:

```
# bazel --toolchain_resolution_debug, target platform //build/platforms:linux_x86_64_musl
before   @@toolchains_musl++...+musl-1_2_3-...-target-x86_64-linux-musl
after    @@llvm+//toolchain:linux_x86_64_cc_toolchain

# and for the glibc platform //build/rbe:rbe_platform
before   @@toolchains_buildbuddy++...+buildbuddy_toolchain//:ubuntu_local_cc_toolchain
after    @@llvm+//toolchain:linux_x86_64_cc_toolchain      <- same toolchain
```

Run 6 also compiled libc++, compiler-rt and libunwind from source — 5,308 actions against the baseline's 51. The
gcc musl path never builds those, so the provenance is not in doubt.

---

## Finding — musl stops being a toolchain, and that is the real fix

Of the 462 toolchains hermetic-llvm declares, none has "musl" in its name. There is one cc toolchain per
(exec, target) pair and libc is a property of the target platform —
`@llvm//constraints/libc:{musl, gnu.2.28 … gnu.2.44}` on a setting that defaults to `unconstrained`.

That is a structural change, not a tidier implementation. The failure mode this repo hit twice — a glibc
toolchain matching a musl platform and winning on registration order, producing a "static" binary with
`libstdc++.so.6` in `DT_NEEDED` — cannot occur when there is only one candidate. It also makes the hand-rolled
`linux_libc` / `linux_glibc` / `linux_musl` constraint trio redundant.

**This does not extend to Rust.** The wrappers in `//build/rust` and their must-precede registration order stay
exactly as they are. That race lives inside rules_rust — which derives `target_compatible_with` from the triple,
and `@platforms` has no musl constraint — and is untouched by the cc toolchain. Both runs correctly selected
`rust_..._x86_64-unknown-linux-musl`.

---

## Finding — zero-sysroot is literal

The complete include path of the OpenSSL compile, taken from the run-2 command line:

```
--sysroot=/dev/null -nostdlibinc
-isystem external/llvm++kernel_headers+linux_kernel_headers_x86.6.9.12/include
-isystem external/llvm++glibc+glibc_headers_x86_64-linux-gnu.2.39/include
-isystem external/llvm++llvm_toolchain_minimal+.../lib/clang/22/include
-Xclang -internal-isystem external/llvm++llvm+llvm-project/compiler-rt/include
```

Not one path from the executor image. The glibc version is a declared input rather than a property of the base
image, which is precisely what the speculative include-path list in `../../../MODULE.bazel` was trying and failing to
approximate.

**The image is demoted, not eliminated.** `AR` and `CC` resolved to hermetic toolchain paths, but openssl-src
invoked `RANLIB="ranlib"` as a bare name off the executor's `PATH`, as it does for `perl` and `make`. The image
stops being *the toolchain* and becomes a posix-utility sandbox — a much smaller and more stable contract, but
not zero.

---

## Costs

- **Cold-start runtime build.** The first musl build compiled libc++, compiler-rt and libunwind from source —
  350s and 4,517 remote actions. Cached afterwards, but it is a real first-build cost per (exec, target, libc)
  combination and it will show up on any cache eviction.
- **Repo fetches on the client.** Roughly 40 MB of prebuilt toolchain plus per-version glibc and kernel header
  archives, fetched by repository rules on the Bazel client and uploaded to the CAS.
- **Full rebuild on switch.** The cc toolchain is part of every action key, so the first build after flipping any
  target platform has no cache hits — the same effect the `gold` to `lld` change had.
- **Pre-1.0 dependency.** 31 BCR releases to date, currently 0.8.17. It moves fast.

---

## Change set — six files, opt-in only

| File | Change |
|---|---|
| `../../../MODULE.bazel` | `bazel_dep(name = "llvm", version = "0.8.17")` — deliberately **not** registered, so the default build is provably unchanged |
| `MODULE.bazel.lock` | resolution |
| `../../../build/platforms/BUILD.bazel` | libc + pie constraints on the two musl platforms; verified inert |
| `../../../third_party/rust_patches/openssl_src_runfiles_patch` | the `-target` filter; round-trip verified |
| `../../../third_party/crates/openssl-src-300.6.1-3.6.3/src/lib.rs` | the applied copy, per the vendor.sh convention |
| `../../../scripts/vendor.sh` | comment only — it described one Configure fix and there are now two |

Total: +94 / -19.

Opt-in is `--extra_toolchains=@llvm//toolchain:linux_x86_64_to_linux_x86_64` and nothing else. Every toolchain
currently registered still wins by registration order, which is what keeps the baseline provable at each step.

---

## Not covered

- **aarch64 glibc cross.** Untested. Would retire the hand-rolled `aarch64_linux_gnu_cc_toolchain` that hardcodes
  `/usr/bin/aarch64-linux-gnu-*`.
- **cgo.** Every Go binary that links C.
- **Erlang/Elixir NIFs.** They compile through the cc toolchain too.
- **macOS.** hermetic-llvm fetches the SDK from `swcdn.apple.com` — network access and a licensing call.
- **The eBPF path.** Unaffected either way: the LLVM ceiling there is rustc's bundled LLVM against bpf-linker's,
  not the cc toolchain's.

---

## Sequencing

This branch is not ready to land, and should not land first. Both this and
`refactor/hex-deps-module-extension` edit `../../../MODULE.bazel` heavily.

1. Land the Hex module-extension work and the `rules_aya_ebpf` extraction, so the dependency declarations are
   already in their final shape.
2. Rebase this experiment onto that and re-run all six runs — the branch is currently based on `no-clang`, which
   predates both.
3. Extend coverage to the aarch64 cross and cgo before proposing a default flip.
4. Flip target platforms one at a time. Only then delete `@toolchains_musl`, the hand-rolled aarch64 toolchain,
   the `linux_libc` constraint trio, and the cross-compile apt list in `Dockerfile.rbe`.
