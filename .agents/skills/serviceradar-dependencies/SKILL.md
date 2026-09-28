---
name: serviceradar-dependencies
description: Use when fetching, installing, or updating JavaScript, Python, Rust, Cargo, Bazel crate, OpenSSL, or pq dependencies.
user-invocable: false
metadata:
  internal: true
---

# ServiceRadar Dependency Rules

- Rust dep bump (cargo + Bazel in one go): `make update-rust-deps REPIN=workspace`, or `scripts/update-rust-bazel-deps.sh [update-mode] [verify-target]` — runs `cargo update` → `cargo check` → `bazel run //third_party/crate_mirror:sync` → `bazel build`. To only refresh the vendored archives after hand-editing the root `Cargo.toml`: `bazel run //third_party/crate_mirror:sync`. See [Rust Dependency Management](#rust-dependency-management).

## Socket Firewall

Prefer Socket Firewall for supported dependency-fetching commands. Prefix JavaScript/TypeScript package manager calls with `sfw`, especially `npm` commands such as `sfw npm ci`, `sfw npm install`, and `sfw npm run ...` when the command may fetch packages. Also use `sfw` for supported Python and Rust package managers (`pip`, `uv`, and `cargo`) when they may download dependencies. Web-NG uses Bun for asset builds; prefix Bun package-manager invocations with `sfw` in CI and Bazel release tooling as a best-effort firewall even though Socket Firewall Free only officially guarantees npm/yarn/pnpm for JavaScript. Socket Firewall Free does not currently support Go, Bazel, or Hex/Mix, so do not wrap those commands unless Socket adds support.

- **Rust**: run `cargo fmt` + `cargo clippy` on touched crates (notably `rust/srql`); leverage existing Diesel helpers + CNPG pooling utilities before adding new abstractions.

## Rust Dependency Management

Full detail, with the reasoning behind each rule: **`rust/README_RUST.md`**. The traps
below are the ones an agent hits by accident.

- **Every dependency version lives in `[workspace.dependencies]` in the root `Cargo.toml`**,
  alphabetically sorted. A crate under `/rust/` NEVER names a version — it uses
  `{ workspace = true, features = [...] }`. Cargo and Bazel both read this one list, which
  is what keeps the two builds from drifting. (`sha2` in `rust/srql` is a documented
  exception; `rust/rdp-connector-probe` is deliberately detached.)
- **A green `cargo check` does NOT prove the Bazel build.** Finish every dependency change
  with `bazel build //rust/...`, and use `cargo check --workspace --lib --bins --tests` —
  plain `cargo check` skips test code that Bazel compiles.
- **`cargo check -p <crate>` must pass standalone.** Workspace feature unification hides a
  missing `features = [...]` behind another crate that enabled it.
- **`default-features = false` is only safe when the compiler catches the loss.** A dropped
  default that is a *runtime* backend compiles clean and fails in production — this exact
  mistake removed `ureq`'s TLS transport.
- **Refresh the vendored archives only with `bazel run //third_party/crate_mirror:sync`.**
  Source patches are `crate.annotation` `patches` entries applied at fetch time, so they
  are declared build inputs, not edits to a tree on disk.
- **OpenSSL comes from the `@openssl` BCR module** — never a vendored `openssl-src` build
  and never the machine's. Keep the `openssl-sys`/`pq-src` pairing in `//MODULE.bazel`, and
  set `OPENSSL_LIB_DIR`/`OPENSSL_INCLUDE_DIR` explicitly: `openssl-sys` reads them before
  `OPENSSL_DIR`, so the RBE executor's own OpenSSL gets linked silently otherwise.
- **`pq-src` is patched and pinned** (`pq-sys = "=0.7.5"`, patch in
  `//third_party/rust_patches/`). A bump that invalidates the patch fails the fetch loudly —
  do not paper over it; the patch is macOS-only, so skipping it leaves Linux CI green and
  breaks a developer's machine later.
- **Pass `cargo_only = True` to `all_crate_deps`**, and add the `@crates//:<name>` label by
  hand in any `BUILD.bazel` that lists deps explicitly — Bazel will not infer that one.
- **`rust_test(crate = ":x")` does NOT inherit `crate_features`** — repeat them, or the test
  compiles a different crate than the one that ships.
- **Every crate with `#[cfg(test)]` code needs a `rust_test` target.** flowgger silently
  carried a 2016 `serde_json` and fully broken config parsing because nothing ran its tests.
