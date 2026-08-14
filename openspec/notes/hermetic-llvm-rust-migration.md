# Migrating to hermetic LLVM and rules_rs

**An experience report**

| | |
|---|---|
| Date | 2026-08-14 |
| Branch | `feat/hermetic-llvm` |
| Result | `bazel build //...` clean, `bazel test //...` 142/142, warm rebuild 4.1s |
| Scale | 781 files, +3,354 / -113,673 |
| Versions | hermetic-llvm (BCR: `llvm`) 0.8.17 / LLVM 22.1.6, rules_rs fork @ `d994e53`, Bazel 9.2.0 |

This is a write-up of an actual migration, intended for anyone repeating it on another repository. It
records the traps in the order they were hit, because most of them are invisible until you hit them and
several fail *silently* rather than loudly.

The two changes are separable in principle and were done together here. If you are doing both, do
rules_rs first: it is mechanical and its failures are loud, whereas the toolchain failures are subtle.

---

## Part 1 — rules_rs

### The vendored-crates problem

rules_rs downloads each crate from the registry. If your repo vendors its third-party Rust sources
(`cargo vendor`), you want them resolved from disk instead. That is `crate.from_cargo(vendor_dir = ...)`,
which at time of writing is **not upstream** — this migration runs a fork.

The payoff is large: the vendor tree becomes *sources only*. rules_rs generates the BUILD files and the
`@crates` hub at fetch time, so 708 checked-in generated BUILD files were deleted. Regenerating the tree
becomes a plain `cargo vendor` rather than a bespoke rendering step.

Two hazards are worth knowing if you implement this yourself, because both corrupt the *user's* source
tree rather than the repository cache:

- **Nested workspace markers.** A vendored crate that ships its own `BUILD`, `BUILD.bazel`, `WORKSPACE*`,
  `MODULE.bazel` or `REPO.bazel` will, once symlinked into the repository root, make Bazel treat that
  directory as a nested workspace — and a checked-in `BUILD.bazel` collides with the generated one. Skip
  those names when symlinking.
- **Patched crates cannot be symlinked.** Bazel's native patch implementation follows symlinks, so the
  patch lands on the checked-in file in your workspace, not on the repository's copy — and re-applies on
  every refetch, starting from an already-patched file. Patched crates must be copied.

### There is no `crate.spec`

rules_rust lets you add a crate that no workspace member depends on. rules_rs does not. If you need a
binary-only crate in the graph — `protoc-gen-prost` and `protoc-gen-tonic` for the prost toolchain, in
our case — you must create a real workspace member that depends on it. We added `//rust/protoc-plugins`,
a crate with no code whose entire purpose is its `Cargo.toml`.

### `all_crate_deps` needs `cargo_only = True`

Without it, the result also carries first-party workspace members as `//rust/...` labels. Every BUILD
file that already lists those by hand then fails with a duplicate. This is a one-line fix applied
everywhere, but the error message does not point at the cause.

### `build_script_env` does not resolve labels

`build_script_data` is `attr.label_list`, so its labels are canonicalized. `build_script_env` is
`attr.string_dict`, so its values are passed through **verbatim** — a `$(execpath //foo)` in it resolves
against the crate's own repository, not yours. Write `$(execpath @@//foo)`.

### Build scripts do not run in the execroot

rules_rs runs build scripts in a sandbox directory. Any build script that reads a repo-relative path
(`../../proto/foo.proto`) breaks. Add `features = ["symlink-exec-root"]` to restore the execroot as the
working directory, and make the script probe both locations:

```rust
let path = if Path::new("proto/flow/flow.proto").exists() {
    "proto/flow/flow.proto"
} else {
    "../../proto/flow/flow.proto"
};
```

One extra wrinkle: if the crate has its *own* directory with the same name as the execroot symlink
(`rust/otel/proto/`), the symlink is shadowed and the file is never found. Stage the file explicitly with
`copy_file` instead.

### `rust_test` does not inherit `crate_features`

`rust_test(crate = ":x")` compiles a *different* crate than the one that ships unless you repeat the
features. Silent, and it produces test passes that mean nothing.

---

## Part 2 — hermetic LLVM

### libc becomes a property of the target platform

This is the structural change, and it is the good part. There is one cc toolchain per (exec, target)
pair, and libc is a constraint on the *target platform*
(`@llvm//constraints/libc:{musl, gnu.2.28 … }`), defaulting to `unconstrained`.

The failure mode that motivates the whole migration — a glibc toolchain matching a musl platform and
winning on registration order, producing a "static" binary with `libstdc++.so.6` in `DT_NEEDED` —
becomes impossible, because there is only one candidate.

### musl needs TWO independent constraints

This one cost real time. The C toolchain and the Rust toolchain select on *different* constraints:

```python
"@llvm//constraints/libc:musl",              # selects the C toolchain
"@rules_rs//rs/platforms/constraints:musl",  # selects the Rust toolchain
```

With only the first, the Rust toolchain silently keeps its default (`linux_libc` → glibc) and the link
fails with `undefined symbol: open64` — an error that points nowhere near the cause.

### `--sysroot=/dev/null -nostdlibinc` is literal

The complete include path contains not one directory from the executor image. Everything comes from
declared inputs: kernel headers, glibc headers, the clang resource dir, compiler-rt.

The consequence to plan for: **anything that resolves a system library through pkg-config breaks.**
pkg-config commonly emits only `-lssl -lcrypto` and leaves the header and library directories to the
compiler's defaults. gcc has such defaults. This toolchain deliberately has none:

```
dtls.h:3:10: fatal error: 'openssl/err.h' file not found
ld.lld: error: unable to find library -lssl
```

There is no flag that fixes this. Either the dependency gets vendored and built from source, or that
target keeps the system compiler. Budget for an escape hatch — we kept two packages on the image's gcc
and documented why in the code.

### `-target` vs `--target=`

A clang toolchain emits the *separated* `-target x86_64-linux-gnu` form. OpenSSL's `Configure` has no
`-target` flag and takes its target as a positional argument, so it reads the bare triple as a second
target and dies with `target already defined`. GCC never emitted that form, so this had never surfaced.
Filtering the pair is safe: the same command line carries `--target=<triple>`, which parses correctly.

Expect this class of bug from any build system that parses `CFLAGS` itself.

### Platform *names* can collide

Under `--experimental_platform_in_output_dir`, the output directory is derived from the platform **name**.
Ours collided with rules_go's, producing "conflicting actions" on the LLVM object files. Renaming the
platforms (`linux_x86_64`, `linux_aarch64`, …) fixed it. Nothing about this is discoverable from the
error message.

### Shared libraries loaded outside Bazel need static runtime linkage

A dynamically linked NIF gets an `$ORIGIN`-relative rpath into `_solib_*`, which breaks the moment
anything copies the `.so` out of `bazel-bin` — as `mix release` does:

```
libc++.so.1: cannot open shared object file
```

`cc_runtime_linkage = "static"` on the shared-library rule. Applies to any plugin/NIF/dlopen artifact,
not just Elixir.

---

## Part 3 — the executor image

### The compiler leaves, and so does everything that depended on it

Removing the cross-compilers and system LLVM took the image from **926.47 → 449.79 MiB packed (−52%)**.

But `llvm-dev` had been supplying `libncurses-dev` transitively, and OTP's `erts/configure` probes
`tgetent` in `-ltinfo/-lncurses/-lcurses/-ltermcap`. Removing LLVM broke the Erlang build with
`No curses library functions found` — a failure with no visible connection to the change.

Two lessons:

- **Diff the image by FILE, not by package.** A package-name diff misses transitively-provided headers
  and libraries entirely. Comparing `/usr/include/**` and `**/lib*.so` between the two images found it
  in one step after a package diff had sent us down the wrong path.
- **Declare what you need explicitly.** `libncurses-dev` is now a named dependency rather than a
  side effect of the compiler package.

### The image is in every action key

Changing `container-image` invalidates the entire remote cache. This is worth planning around, because
it dominates the experience of the migration:

| | |
|---|---|
| Cold (image bumped) | 2,998s, 31,056 remote actions, 879 MB downloaded |
| Warm (no change) | **4.1s**, 49,942 action-cache hits |

During the cold pass, upload consumed 207,784s of ~299,800 available thread-seconds — **69% of all
capacity spent moving bytes, not compiling**. Actual compiler wall time was 10,424s. Hermeticity moves
the toolchain from "invisible property of the image" to "action input that must exist in the CAS", and
you pay that once per cache generation.

Do not bump the image more than you must. We invalidated the cache five times in one day (two image
tags, plus three build-graph changes) and paid a cold pass each time. The steady state is 4.1 seconds.

### The image is demoted, not eliminated

`CC` and `AR` resolve to hermetic paths, but from-source builds still invoke `perl`, `make` and `ranlib`
as bare names off `PATH`. The image stops being *the toolchain* and becomes a posix-utility sandbox —
a much smaller and more stable contract, but not zero.

---

## Part 4 — Elixir/BEAM specifics

Skip this part if you have no Elixir. The transferable lesson is in the last section.

### Scope the toolchain to what actually compiles C

Exporting `CC`/`CFLAGS` from every Mix package would put the whole clang toolchain into ~271 packages'
action inputs and rebuild all of them on an LLVM bump, to benefit the ~20 that run a compiler. Detect
from the package's **own** sources (`bundlex.exs`, `Makefile*`, `*.c/cc/cpp`), not its dependency
closure.

### Use the loaded `cc_common`, not the global

`@rules_cc//cc/common:cc_common.bzl`. The same-named global exposes neither `configure_features` nor
`create_compile_variables`, and the error tells you only that the field does not exist.

Also: `rules_foreign_cc`'s `get_flags_info`/`get_tools_info` resolve `defines` by reading `CcInfo` off
every `ctx.attr.deps` entry. If your rule's `deps` hold something else, they fail analysis outright.

### Do not change a platform to change a compiler

Bundlex ships a toolchain that reads `$CC` — but reaching it requires setting `CROSSCOMPILE`, which also
feeds `Bundlex.get_target/0`, from which plugins derive their precompiled-dependency URLs. Setting it
made every one of them resolve `{:precompiled, nil}` and fall back to pkg-config, failing on packages
that had nothing to do with the compiler. Patching the existing toolchain to read `$CC` was a fraction
of the blast radius.

### Two silent failures worth naming

Both cost more time than any compiler error, because neither reported anything:

- **`ln -sn src dir/`** — `-n` makes `ln` treat the destination as a normal file rather than a directory
  to link into, so every link failed. It was wrapped in `2>/dev/null || true`, which hid it. The symptom
  appeared three layers away as a missing module at compile time. *Do not suppress errors in build
  glue.*
- **`$ORIGINAL_DIR` reaching `make`** — shell-quoted with single quotes, the variable was never expanded
  by the shell, and `make` expanded `$O` as an undefined make variable, invoking
  `RIGINAL_DIR/.../clang`. Values crossing into another interpreter must be fully expanded first.

### `ERL_LIBS` is a path list — a 908-second lesson in graph shape

`rules_erlang` merges every dependency into one private `deps/` tree per consumer, and a dependency whose
`ebin` is a directory is merged with a `cp -RL` action. That action belongs to the **consumer**, so a
dependency is copied once per package that depends on it: measured, 88 copy actions for 14 distinct
dependencies, `bundlex` copied 26 times, every copy byte-identical, 908s and nothing compiled. They
cannot share a cache entry because the output *path* is part of the action key.

None of that merging was necessary. `ERL_LIBS` is colon-separated precisely so it can name several
directories, and the rule already emitted `<app>/ebin`. Handing Erlang the directories directly deleted
the entire action class.

**The general lesson:** when an action appears N×M times, check whether the artifact is owned by the
wrong target. Byte-identical outputs that cannot share cache are always an ownership bug.

---

## What I would do differently

1. **Do rules_rs and hermetic LLVM as separate landings.** They interact only through the platform
   definitions. Debugging both at once means every failure has two candidate causes.
2. **Diff images by file from the start.** The package-name diff was actively misleading.
3. **Budget the cold passes.** Decide up front how many image bumps you will take, and batch every
   Dockerfile change into one of them.
4. **Grep the build glue for suppressed errors before starting.** `2>/dev/null`, `|| true`, and silent
   fallbacks turn a five-minute fix into an hour of bisection.
5. **Enumerate what links system libraries before migrating.** `--sysroot=/dev/null` will find them all
   for you, one build failure at a time; a `pkg-config` grep finds them in one pass.

## Still open

- Hermetic OpenSSL for the two packages that link it through pkg-config. Note the repo already builds
  OpenSSL from source under this toolchain for Rust (`openssl-src`), so the capability exists — what is
  missing is exposing it as a `cc_library` other rules can consume.
- The `local_precompiled` patch falls back to a network download when an archive name stops matching.
  It should hard-fail instead; a silent network fetch inside a build action is exactly what the patch
  was written to prevent.
- aarch64 cross and cgo coverage — see the multi-arch OCI plan.
