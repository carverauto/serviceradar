# Rust Source Tree `/rust/`

Every Rust crate here is built two ways: by **Cargo** (for local work, `cargo test`, IDEs) and
by **Bazel** (for CI, release artifacts, and everything downstream). Both read the *same*
dependency versions from one place -- the root `Cargo.toml` -- so the two builds cannot drift.

This document explains that arrangement, how Bazel gets its crates, and the workflow for
updating dependencies without breaking either build.

---

## 1. One place for every dependency

**All external dependency versions live in `[workspace.dependencies]` in the root
`Cargo.toml`.** A crate under `/rust/` never names a version:

```toml
# rust/otel/Cargo.toml
[dependencies]
anyhow = { workspace = true }
tonic  = { workspace = true, features = ["tls-ring"] }
```

Entries are kept **alphabetically sorted**. There are ~98 of them.

### Large vs small crates

Two shapes, by design:

```toml
# Large: the workspace turns defaults off; each consumer opts in to what it uses.
# `std` is hoisted here because nothing in this workspace is no_std.
serde  = { version = "1.0", default-features = false, features = ["std"] }
rustls = { version = "0.23", default-features = false, features = ["std"] }

# Small: a bare version, defaults on.
anyhow = "1.0"
hex    = "0.4"
```

**When defaults are load-bearing, the crate keeps them even if it is "large"** -- i.e. no
`default-features = false`, whether written as a bare version or as a table that only adds an
extra. If every consumer needs the default set, disabling it just means re-listing those
defaults in each crate -- noise with a real risk of silently dropping one. Current examples,
each with the reason recorded inline in `Cargo.toml`:

| crate | why defaults stay |
|---|---|
| `async-nats` | `jetstream`, `nkeys`, `ring` -- all consumers need them |
| `toml` | `default = std,serde,parse,display` is effectively the whole crate |
| `axum` | consumers add only extras (`ws`, `macros`) *on top of* the defaults |
| `prometheus` | `protobuf` is load-bearing (netprobe's `get_counter().value()`) |
| `env_logger` | `humantime` is `timestamp_seconds`; dropping `regex` breaks `RUST_LOG` filters |
| `ureq` | **`rustls` IS the TLS transport** -- disabling it compiles fine and fails at runtime |

> **The `default-features = false` trap.** Dropping a default is only safe when the
> compiler catches it. `ureq` is the cautionary tale: turning defaults off removed its TLS
> backend, compiled cleanly, and would only have failed when something actually fetched over
> https. Before disabling defaults on a crate, ask what the defaults *do* -- not just whether
> it still builds.

### Every crate must build standalone

`cargo check -p <crate>` must pass **on its own**, not just as part of the workspace. Cargo
unifies features across a workspace build, so a crate that forgets `features = ["transport"]`
still compiles because some *other* crate enabled it. That is an accident waiting to break the
moment the other crate changes. Bazel compiles per-target and is less forgiving.

```bash
cargo check -p srql --lib --bins --tests   # must pass in isolation
```

### Exceptions

Only one crate holds a local version, and it is documented at the declaration:

- **`rust/srql`: `sha2 = "0.10.9"`** -- BLOCKED. `pagination.rs` builds `Hmac<Sha256>`; `hmac
  0.12` is built on `digest 0.10` while the workspace `sha2 0.11` moved to `digest 0.11`. The
  trait bounds do not meet. Unblocking needs `hmac` on `digest 0.11`, or moving the cursor MAC
  off `hmac`.

`rust/rdp-connector-probe` is deliberately **detached** from the workspace: it is a
review-only, date-audited IronRDP probe with its own `[workspace]` and lockfile. Leave it be.

---

## 2. How Bazel gets its crates

Bazel does **not** reach the network for crates. Every registry crate is vendored on disk
under `//third_party/crate_mirror` as its `.crate` archive -- the same file Cargo's own
registry cache holds -- refreshed by `bazel run //third_party/crate_mirror:sync` from the
`//:Cargo.lock` that Cargo uses.

Bazel finds them through `--distdir`, set in `//.bazelrc`. `rules_rs` asks crates.io for
`{crate}/{crate}-{version}.crate` first, and that basename is the only one Bazel's distdir
matches on, so each archive resolves from disk. It is a fallback rather than an enforcement:
a crate missing from the mirror is downloaded, so a stale mirror degrades rather than breaks.

Resolving `//:Cargo.lock` as a single universe is what keeps the two builds honest: one
`prost`, one `tonic`, one `tokio`.

`rules_rs` generates the per-crate BUILD files and a hub repository, `@crates`. Crates
reference the hub:

```python
load("@crates//:defs.bzl", "all_crate_deps")

rust_library(
    name = "otel_lib",
    deps = all_crate_deps(normal = True, cargo_only = True),   # reads this crate's Cargo.toml
)
```

- **`all_crate_deps(...)`** picks deps up from the crate's `Cargo.toml` automatically.
- **`cargo_only = True`** is not optional here. Without it `all_crate_deps` also returns this
  crate's first-party workspace-member deps as `//rust/...` labels, and every BUILD file in
  this repo already lists those by hand -- so each one would be named twice, which Bazel
  rejects as a duplicate label.
- **There is no `proc_macro` dep kind.** Proc-macro crates are part of `normal`;
  `rules_rust`'s own macro splits `deps` by `CrateInfo` type, so a separate
  `proc_macro_deps = all_crate_deps(proc_macro = True)` is both unnecessary and a duplicate.
- **Naming a crate explicitly** is a plain label: `"@crates//:tempfile"`. These must be
  **updated by hand** when you add a dependency, and the name must exist in that crate's
  `Cargo.toml` (the unversioned alias is only emitted for direct dependencies of a workspace
  member; otherwise use `@crates//:<name>-<version>`).

### Two Bazel-only gotchas

**`rust_test(crate = ":x")` does NOT inherit `crate_features`.** They must be repeated, or the
test compiles a *different* crate than the one that ships:

```python
rust_test(
    name = "flowgger_lib_test",
    crate = ":flowgger_lib",
    crate_features = ["gelf", "syslog", "tls"],   # must mirror the library
)
```

**Test fixtures need more than `data`.** Bazel runs tests from the runfiles tree, so a bare
relative path resolves to nothing. Declare the `data` *and* resolve the path (see
`config.rs::fixture_path` in flowgger, or `satori.rs::fixture_corpus_dir` in netprobe):
`CARGO_MANIFEST_DIR` -> `TEST_SRCDIR` -> relative.

---

## 3. Updating dependencies

`bazel run //third_party/crate_mirror:sync` is the **only** supported way to refresh the
vendored archives. It verifies every download against the checksum `Cargo.lock` already
records, and prunes archives no longer in the lock.

### Routine update

To move the lock and re-vendor in one go, use the wrapper -- it runs all four steps below in
order and stops at the first failure:

```bash
make update-rust-deps                        # cargo update --workspace
make update-rust-deps REPIN=full             # cargo update (everything)
make update-rust-deps REPIN=diesel@2.3.7     # one crate, pinned

# same thing, directly:
scripts/update-rust-bazel-deps.sh [update-mode] [verify-target]
scripts/update-rust-bazel-deps.sh --help
```

When you hand-edit a version in the root `Cargo.toml` instead, run the steps yourself:

```bash
# 1. Bump in the ROOT Cargo.toml only (never in a crate under /rust/).
$EDITOR Cargo.toml

# 2. Cargo side. --lib --bins --tests matters: plain `cargo check` skips test code,
#    and Bazel compiles tests.
cargo check --workspace --lib --bins --tests
cargo test  --workspace

# 3. Refresh the vendored archives.
bazel run //third_party/crate_mirror:sync

# 4. Bazel side. Cargo passing is NOT proof -- see the warning below.
bazel build //rust/...
bazel test  //rust/...
```

> **A green `cargo check` does not mean Bazel is green.** Cargo.lock is
> feature-independent and keeps optional deps that are never activated; `cargo vendor`
> vendors the whole lock. Cargo prunes what Bazel still builds. Always finish with
> `bazel build //rust/...` before claiming a dependency change works.

### Adding a dependency

1. Add it to `[workspace.dependencies]` in the root `Cargo.toml` (alphabetically).
2. Reference it as `{ workspace = true }` in the crate.
3. If that crate's `BUILD.bazel` names its deps explicitly as `"@crates//:<name>"` labels
   rather than through `all_crate_deps`, **add the label there too** -- Bazel will not infer
   it.
4. `bazel run //third_party/crate_mirror:sync`, then `bazel build //rust/...`.

### Breaking-change migrations

Work **one dependency at a time**, and read the crate's changelog before touching code -- the
compiler will not tell you about behaviour changes:

- **Runtime-only breaks compile fine.** axum 0.8 changed path params (`/:id` -> `/{id}`) and
  **panics at router construction**, not at compile time.
- **A moved trait can look like nothing changed.** rand 0.10 re-exports `Rng` from `rand_core`
  and moved the ergonomic methods to `RngExt` -- `use rand::Rng` still compiles, it just stops
  providing `random_range`.
- **Silent skips beat wrong answers.** deep_causality 0.15 rejects cyclic graphs that 0.13
  traversed by silently skipping nodes; the "working" old behaviour was the bug.

### Every crate's tests must be declared in Bazel

If a crate has `#[cfg(test)]` code, it needs a `rust_test` target. This is not bookkeeping:
flowgger sat with a **2016 serde_json**, notify 4.x APIs, and completely broken config parsing
precisely because nothing ran its tests. Check with:

```bash
grep -rl "#\[cfg(test)\]" rust/<crate>/src   # has tests?
grep -n "rust_test" rust/<crate>/BUILD.bazel  # declared?
```

---

## 4. The two patched system crates

Two crates need **source patches** to build under Bazel. They are declared as
`patches` on their `crate.annotation`, so `rules_rs` applies them at fetch time and they are
real, declared build inputs. Patches live in `//third_party/rust_patches/`.

This used to work the other way: a vendor script applied them to the checked-in tree on disk,
because `rules_rs` symlinked that tree into its repository and Bazel's patch implementation
would have rewritten the checkout in place. With the tree replaced by `.crate` archives the
constraint is gone -- and the old arrangement had a real cost, since a patch applied outside
the build graph stops being applied without anything noticing. That is exactly what happened
when the vendored tree was removed.

| crate | patch | why |
|---|---|---|
| `openssl-src-300.6.1+3.6.3` | `openssl_src_runfiles_patch` | `source_dir()` must honour `RULES_RUST_OPENSSL_SRC_DIR` (the crate's baked `CARGO_MANIFEST_DIR` is a stale sandbox path under Bazel), and Configure must ignore two cc flags it cannot parse: `-no-canonical-prefixes` (rejected outright) and the separated `-target <triple>` form a clang driver emits (read as a second positional target). |
| `pq-src-0.3.11+libpq-18.3` | `pq_src_fortify_patch` | macOS only: re-assert `-D_FORTIFY_SOURCE=0` at the end of `$CFLAGS` so it overrides Bazel's `-U_FORTIFY_SOURCE` (cc-rs applies env `CFLAGS` last), which otherwise re-enables fortify `strlcat`/`strlcpy` builtins that clash with libpq's bundled copies. |

These build OpenSSL and libpq **from source**, which is what makes the build portable
(macOS/Alpine/CI) instead of depending on system OpenSSL paths.

### Why they are pinned

Both patches are keyed to an **exact upstream version**, so the root `Cargo.toml` pins them:

```toml
openssl-sys = "=0.9.116"
pq-sys      = "=0.7.5"
```

The pins do **not** reach their build deps -- `pq-sys` declares `pq-src ">=0.2, <0.4"` and
`openssl-sys` declares `openssl-src "300.2.0"` -- so `pq-src`/`openssl-src` can still slide on a
`cargo update`. That is what the asserts are for.

### The asserts (do not weaken them)

A patch that does not apply fails the crate's fetch, loudly and at the point of use. Do not
work around that by dropping the patch:

- A silently skipped patch is the worst outcome available here. `pq-src`'s fix is **macOS
  only**, so a skipped patch leaves Linux CI green and breaks a developer's machine later, far
  from the cause.
- The pins (`openssl-sys = "=0.9.116"`, `pq-sys = "=0.7.5"`) are what stop a routine
  `cargo update` from moving these crates out from under their patches.

### Bumping a patched crate (deliberate, never accidental)

1. Change the pin in the root `Cargo.toml`.
2. `bazel run //third_party/crate_mirror:sync`, then `bazel build //rust/...`. **The fetch
   will fail** -- that is the design.
3. Regenerate the patch against the new upstream source, in
   `//third_party/rust_patches/`.
4. Rebuild on **macOS and Linux** -- the pq-src patch only manifests on macOS.

---

## 5. Crate annotations

Per-crate build tweaks live in `//MODULE.bazel` as `crate.annotation(crate = "<name>", ...)`
tags, not in a vendor rule. Three crates carry one:

| crate | why |
|---|---|
| `openssl-src` | Exposes its C source tree as filegroups, aliased into the hub with `extra_aliased_targets` so `openssl-sys` below can name them. |
| `openssl-sys` | Points the build script at those filegroups and at the perl wrapper in `//third_party/rust_patches`, so OpenSSL builds from the vendored source. |
| `protoc-gen-prost`, `protoc-gen-tonic` | `gen_binaries`, so the plugin binaries `//build/rust/prost_toolchain` runs actually get targets. |

**Labels in an annotation are resolved against `MODULE.bazel`**, which is the root repository
-- a relative label cannot name a target in the generated crate package. Expose such a target
with `extra_aliased_targets` and refer to it as `@crates//:<alias>`, or put it in the main
workspace and use an absolute label. Both patterns are in use above.

**A crate reaches the graph only as a real dependency of a real workspace member.** There is no
equivalent of `crate_universe`'s `packages` attribute to conjure one. That is what
`//rust/protoc-plugins` is for: it has no code, and its `Cargo.toml` exists to pin the two
protoc plugins and `prost-types` so the hub emits stable unversioned aliases for them.

---

## 6. Crate code structure

Everything above is about *dependencies*. This section is about *layout*, and it applies to
every crate under `/rust/`.

### One type, one module

Three base directories, each holding one item per file:

```
src/errors/mod.rs    # each error type in its own file
src/traits/mod.rs    # each trait in its own file
src/types/mod.rs     # each type in its own file
```

A **small** type -- whole implementation under ~25 lines -- is a single file named for the
type in snake_case:

```
src/types/small_type.rs
```

A **complex** type is a folder module. `mod.rs` holds the type definition and its
constructors; every trait implementation gets its own file named after the trait (or trait
group) it implements:

```
src/types/uncertain/mod.rs                  # definition + constructors
src/types/uncertain/uncertain_debug.rs      # impl Debug
src/types/uncertain/uncertain_part_eq.rs    # impl PartialEq
```

### Tests mirror `src/`

`tests/` replicates the `src/` tree exactly, with `_tests` appended to the file name:

```
src/errors/normal_error/normal_error.rs
tests/errors/normal_error/normal_error_tests.rs
```

Every test file must be registered in its `mod.rs` with the correct `#[cfg(test)]`
annotation, and each module registered with its parent. Folder modules must also be
declared in `rust/<crate>/tests/BUILD.bazel` -- see also *Every crate's tests must be
declared in Bazel* in section 3.

**Shared test helpers live in the `src/` tree, not `tests/`:**

```
src/utils_tests/mod.rs
```

This is not a style preference. Bazel cannot reach helper files that live inside `tests/`,
but it can reach all of `src/` during testing. Putting helpers under `src/` is what makes
them visible to the Bazel test targets at all -- with the deliberate side effect that the
helpers are themselves tested and count toward coverage.

### Exports and imports

- All public types, traits, and errors are re-exported from `src/lib.rs`.
- Internal modules stay private at the root.
- **Prelude files are prohibited.**
- Import from another crate at its root, never a nested path:

```rust
use deep_causality_discovery::{ConsoleFormatter, ProcessAnalysis, ProcessResultFormatter};
```

### Error types

A public error is a **tuple struct wrapping a classification enum**, not a bare public
enum. The wrapper is what makes new failure modes non-breaking: variants can be added, and
the internal representation can later gain context or a source chain, without changing the
public type.

```rust
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct PhysicsError(PhysicsErrorEnum);           // field is PRIVATE

/// Detailed classification of physics-related errors.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
#[non_exhaustive]
pub enum PhysicsErrorEnum {
    /// A fundamental physical invariant was violated.
    PhysicalInvariantBroken(String),
    /// Operations attempted on quantities with incompatible dimensions.
    DimensionMismatch(String),
    /// Absolute zero violations.
    ZeroKelvinViolation,
}

impl PhysicsError {
    pub(crate) fn new(variant: PhysicsErrorEnum) -> Self {
        Self(variant)
    }

    /// Classification, for callers that need to branch on the failure.
    pub fn kind(&self) -> &PhysicsErrorEnum {
        &self.0
    }

    #[allow(non_snake_case)]
    pub fn PhysicalInvariantBroken(msg: String) -> Self {
        Self(PhysicsErrorEnum::PhysicalInvariantBroken(msg))
    }
}
```

`Display` is written by hand, matching on the inner enum, and lives in its own file per the
one-trait-one-file rule (`physics_error_display.rs`). `std::error::Error` likewise. Because
`Display` is hand-written, `thiserror` buys nothing -- do not add it.

```rust
impl Display for PhysicsError {
    fn fmt(&self, f: &mut Formatter<'_>) -> core::fmt::Result {
        match &self.0 {
            PhysicsErrorEnum::PhysicalInvariantBroken(msg) => {
                write!(f, "Physical Invariant Broken: {}", msg)
            }
            PhysicsErrorEnum::DimensionMismatch(msg) => write!(f, "Dimension Mismatch: {}", msg),
            PhysicsErrorEnum::ZeroKelvinViolation => {
                write!(f, "Zero Kelvin Violation: Temperature cannot be negative")
            }
        }
    }
}
```

Rules that make the pattern actually work:

- **The wrapper's field stays private.** A `pub` field lets callers `match err.0 { .. }`
  exhaustively, which reintroduces exactly the API break the pattern exists to prevent --
  and it violates the field-visibility rule below. Callers branch through `kind()`.
- **Mark the enum `#[non_exhaustive]`.** Private field plus `#[non_exhaustive]` is what
  makes adding a variant a non-event for downstream crates.
- **Give every variant an associated constructor**, `#[allow(non_snake_case)]` and named
  for the variant, so construction reads the same as the variant it produces.
- **Prefer payloads that keep the derives.** `Debug, Clone, PartialEq` should hold for
  every error type, with `Eq, Hash` wherever payloads allow. Watch for third-party types
  that block this: `tonic::Status`, for instance, is `#[derive(Clone)]` only, so store
  `tonic::Code` plus the message instead. That also keeps transport types out of the
  public API.

### Conventions

**Field visibility.** Public types keep *all* fields private; access goes through
constructors, getters, and setters as appropriate. Private types may use public fields
provided they cannot leak outside their defined scope.

**Static dispatch.** Use static dispatch. Avoid `dyn`, trait objects, and dynamic dispatch.
This has a concrete consequence worth stating: `Box<dyn Error>` must not appear in a public
signature -- model errors as concrete typed variants instead.

**Style.** Prefer idiomatic zero-cost abstractions, and functional style (`map`, `flat_map`,
`filter`) over manual loops when working with collections.

**Safety.** No `unsafe`. Exemptions are rare and must be documented at the site.

---

## 7. Quick reference

```bash
# bump + re-vendor + verify, in one go
make update-rust-deps [REPIN=<mode>] [VERIFY_TARGET=<label>]

# regenerate the vendored tree only (the only supported way)
bazel run //third_party/crate_mirror:sync

# cargo: --lib --bins --tests, or you skip test code.
# The third_party/rust_patches forks fail --tests on a clean tree (undeclared dev-deps),
# so exclude them or you will chase a pre-existing failure.
cargo check --workspace --lib --bins --tests \
  --exclude reqsign-azure-storage --exclude reqsign-google --exclude rperf

# a single crate, in isolation (must pass on its own)
cargo check -p <crate> --lib --bins --tests

# bazel: the one that actually decides
bazel build //rust/...
bazel test  //rust/...
```

| file | what it is |
|---|---|
| `Cargo.toml` (root) | **every** dependency version; alphabetical |
| `third_party/crate_mirror/` | the vendored `.crate` archives (generated -- never hand-edit) |
| `MODULE.bazel` | the `crate.from_cargo` extension + per-crate `crate.annotation` tags |
| `third_party/rust_patches/` | source patches for the two system crates |
| `//third_party/crate_mirror:sync` | refresh the archives from `Cargo.lock`, verify checksums, prune |
| `scripts/update-rust-bazel-deps.sh` | the wrapper: `cargo update` -> `cargo check` -> `crate_mirror:sync` -> `bazel build` (`make update-rust-deps`) |
