## Context

`MODULE.bazel` currently manages Rust deps with crate_universe's `from_cargo`
splicing:

```python
crates.from_cargo(
    name = "rust_crates",
    cargo_config = "//:.cargo/config.toml",
    cargo_lockfile = "//:Cargo.lock",
    manifests = ["//:Cargo.toml"],
)
```

plus three `crates.annotation` blocks (`cri-api`, `openssl-sys`, `openssl-src`) and
three `crates.spec` extras (`libzetta`, `ironrdp-core`, `ironrdp-pdu`). 33 Rust BUILD
files consume it through `load("@rust_crates//:defs.bzl", …)` or direct `@rust_crates//:`
labels.
A second, independent extension (`rdp_connector_crates`) serves
`//rust/rdp-connector-probe` from its own `Cargo.lock`.

rules_rust is 0.65.0. `crates_vendor` and `crate.annotation` are the same primitives
already in the tree.

## Goals / Non-Goals

Goals:
- One vendored crate universe under `//third_party/crates` that fully replaces `@rust_crates`.
- Eliminate the Cargo-splicing step from Rust builds.
- Keep per-crate BUILD changes to a load-path swap (no dep-list churn).
- Preserve cri-api protoc and the referenced optional crates; make OpenSSL portable
  (rustls for flowgger, vendored from-source for libpq) — see D6.

Non-Goals:
- Changing proto codegen (`cargo_build_script` + PROTOC) wiring.
- Changing resolved crate versions or Rust source **beyond** the D6 OpenSSL portability
  work (flowgger→rustls source rewrite; `openssl-sys` `vendored` feature on srql).
- Migrating the separate `rdp_connector_crates` universe (follow-up).
- `remote` vendor mode (documented as a fallback, not adopted — see Decisions).

## Decisions

### D1 — Manifest-based single universe, not a `packages` subset

Vendor with `manifests = ["//:Cargo.toml"]` + `cargo_lockfile = "//:Cargo.lock"` so the
vendored graph is *identical* to today's resolved graph. This is the only design that
avoids the duplicate-crate type clash: there is exactly one `prost`, one `tonic`, one
`tokio`, so shared proto types resolve to the same rlib everywhere.

Rejected: a curated `packages` list (the pilot approach). It creates a disjoint second
copy of every listed crate; any target that shares types (e.g. prost `Message`) with a
still-`@rust_crates` crate fails to compile. Proven with `metric-proto` → `otel`/`rperf-client`.

### D2 — Macro-compatible interface → load-swap only

`crates_vendor` generates `//third_party/crates:defs.bzl` exposing the same
`all_crate_deps` / `crate_deps` / `aliases` macros keyed by the same package names.
Because the 33 BUILD files use only those macros (grep confirms **0** raw `@rust_crates__*`
labels in `rust/`), each file's change is exactly:

```diff
-load("@rust_crates//:defs.bzl", "all_crate_deps", "crate_deps")
+load("//third_party/crates:defs.bzl", "all_crate_deps", "crate_deps")
```

Dep lists (`all_crate_deps(normal = True)`, `crate_deps(["prost"])`, …) are unchanged.

### D3 — Atomic cutover

All 33 load swaps (rust/ files incl. rdp-adapter's direct labels, plus 3 third_party/rust_patches) and the `MODULE.bazel` extension removal land together. Rationale: a
half-migrated tree has some targets on vendored crates and some on `@rust_crates`; wherever
those meet through shared Rust types, the D1 clash reappears. For review, the swaps may be
committed in dependency order within one PR, but the PR is not splittable across releases.
The splice only disappears — and the build only speeds up — once the last `@rust_crates`
reference is gone and `from_cargo` is deleted.

### D4 — Local mode (sources committed), remote as documented fallback

Adopt `mode = "local"` per the "proper local vendoring" goal: crate sources live under
`//third_party/crates/<crate>-<version>/`. Trade-off: the full workspace vendor is large
(the proto-stack pilot alone produced ~110 crates; the whole workspace is on the order of
hundreds), so it adds meaningful source to the repo and to diffs. If that git weight proves
unacceptable, `mode = "remote"` keeps the same single-universe/no-splice properties while
fetching pinned sources at build time (only `BUILD`/`defs.bzl` committed). The choice does
not affect correctness or the D1/D3 constraints.

### D5 — Annotation & optional-crate carry-over

`crates.annotation(crate = "X", …, repositories = ["rust_crates"])` becomes an entry in the
vendor rule's `annotations = {"X": [crate.annotation(…)]}` (drop `repositories`). The three
annotations move verbatim in intent:
- `cri-api`: `build_script_data`/`build_script_env` for `@bazel_tools//tools/proto:protoc`.
- `openssl-sys`: `additive_build_file_content` (perl-wrapper `write_file`), plus
  `build_script_data`/`build_script_env` referencing the openssl-src runfiles/readme.
- `openssl-src`: `additive_build_file_content` (the `openssl_src_runfiles`/`openssl_src_readme`
  filegroups), `patch_args = ["-p1"]`, `patches = ["//third_party/rust_patches:openssl_src_runfiles_patch"]`.

`crate.annotation` accepts `patches`/`patch_args` (absolute labels), but **crates_vendor
local mode does not apply them to the on-disk vendored source** (only the repository-rule/
remote path does). The declaration is kept as the source of truth, and `scripts/vendor.sh`
re-applies the `openssl-src` patch after `bazel run` (idempotent guard). BUILD-file
annotations (filegroups, `build_script_env`, `RULES_RUST_OPENSSL_SRC_DIR`) *are* applied.

`libzetta`, `ironrdp-core`, and `ironrdp-pdu` are dropped from the root `packages`
extras. The production RDP helper gets its exact-pinned connector/CredSSP graph from
the independent `rdp_connector_crates` extension. Keeping a second IronRDP graph in the
root vendor tree would be unused and could silently drift from the shipped helper.

### D6 — OpenSSL portability: rustls where practical, vendored where not

The system-OpenSSL `.bazelrc` overrides (`OPENSSL_LIB_DIR=/usr/lib/x86_64-linux-gnu`, …)
made the build non-portable (they broke every non-Linux host and were never exercising the
vendored path). Resolution:
- **flowgger → rustls** (`ring` provider) for syslog TLS. This removes `openssl` (0.10) +
  `openssl-src` from flowgger's default (`tls`) build; `openssl` 0.10 stays vendored only
  for the optional, non-default `kafka-output`/`security` feature (not compiled by default).
  Cipher-list/DH knobs drop in favour of rustls' safe defaults (TLS 1.2+1.3, AEAD, ECDHE).
  `verify_peer = false` maps to a custom accept-any `ServerCertVerifier`; the client output
  path completes the handshake eagerly (`complete_io`) so a failed connect doesn't lose a
  message already dequeued from the channel.
- **libpq (srql)** keeps `pq-sys` bundled but adds `openssl-sys` `vendored` so libpq
  static-links a from-source OpenSSL where the system overrides are absent.
- **OpenSSL config is platform-scoped, not removed** — the Erlang/OTP + Elixir subtree
  also needs system OpenSSL, and the override paths are Linux paths. So the
  `OPENSSL_DIR`/`OPENSSL_LIB_DIR`/`OPENSSL_INCLUDE_DIR` vars move from the top-level `build`
  config to **`build:linux`** (auto-applied on Linux hosts via
  `--enable_platform_specific_config`): local Linux builds get system OpenSSL for BOTH
  Erlang/Elixir and Rust; macOS builds (vars absent) use the vendored Rust OpenSSL. CI/RBE
  disables platform-specific config (`build:ci --noenable_platform_specific_config`, while
  inheriting `build:remote_base`)
  and is covered by `build:remote_base`'s own OpenSSL vars, so CI keeps system OpenSSL on
  the Linux executor. (An Elixir Bazel build on a macOS host would need a `build:macos`
  OpenSSL path — e.g. Homebrew — separately.)
- **Vendored OpenSSL under Bazel** was the rules_rust #1519 gotcha, never before exercised.
  The `openssl_src_runfiles_patch` (regenerated for openssl-src 300.6.1) fixes `source_dir()`
  to read `RULES_RUST_OPENSSL_SRC_DIR` (the baked `CARGO_MANIFEST_DIR` is a stale sandbox
  path) and strips Configure's `-no-canonical-prefixes`. Verified building from source on macOS.
- **pq-src (libpq from source) fixed:** the macOS build failed with a `strlcat`/`strlcpy`
  conflict because Bazel's cc_wrapper appends `-U_FORTIFY_SOURCE` to `$CFLAGS`, which cc-rs
  applies *last* (cc lib.rs:2064), overriding pq-src's `-D_FORTIFY_SOURCE=0` and re-enabling
  the macOS fortify builtins that clash with libpq's bundled `strlcat`/`strlcpy`.
  `pq_src_fortify_patch` re-asserts `-D_FORTIFY_SOURCE=0` at the end of `$CFLAGS` on macOS
  (applied by `scripts/vendor.sh`). `//rust/srql:srql_lib` builds end-to-end.
- **bmp-collector converted:** the former cargo-in-genrule (`cargo build` in the sandbox)
  becomes a `rust_binary` on the vendored crates, with a `bmp-collector` alias for the
  docker/packaging consumers.

### D7 — Committed vendor-input integrity index

Removing the root `from_cargo` extension also removes its Cargo input hashes from
`MODULE.bazel.lock`; treating that module lock as the root vendor freshness signal is
therefore incorrect. `scripts/vendor.sh` writes a deterministic
`third_party/crates/.serviceradar-vendor-inputs` index containing the SHA-256 of the
root `Cargo.toml`, root `Cargo.lock`, and every workspace member manifest returned by
locked, offline `cargo metadata`. The native add-on version guard checks changed Rust
add-on manifests against this index. Independent crate-universe extensions, including
`rdp_connector_crates`, remain protected by their own hashes in `MODULE.bazel.lock`.

Rejected: exempting vendored Rust add-ons from metadata freshness checks. That would
allow the source manifest and committed dependency tree to diverge at release time.

## Risks / Trade-offs

- **openssl label rewrite (highest risk).** The `openssl-sys`/`openssl-src` annotations
  reference `@rust_crates__openssl-src-300.6.0-3.6.2//:openssl_src_runfiles` and
  `:...readme`. Under vendoring those repo labels change to the vendored crate's labels
  (e.g. `//third_party/crates/openssl-src-3.x.y:...` or the vendor repo's internal target).
  The patch's `source_dir()`/`/external/` path assumptions may also shift. → Mitigation:
  migrate and green-build an openssl-consuming crate (e.g. a TLS-using service) *before*
  the atomic flip; keep openssl config otherwise byte-identical.
- **`.cargo/config.toml`.** `crates_vendor` accepts `cargo_config` as a label, so
  `.cargo/config.toml` must be added to the root `exports_files(...)` (the module
  extension read it directly; the rule needs a target). It carries the net-retry/timeout
  settings used while fetching hundreds of crates.
- **Repin avoided.** The vestigial `crates.spec` extras are dropped rather than added via
  `packages`, so the vendor resolves straight from the committed `//:Cargo.lock` — no
  `--repin`, no workspace-wide `cargo update` version drift.
- **Large diff / repo size** (local mode) → D4 remote fallback.
- **Reviewability of an atomic 32-file + MODULE.bazel PR** → order swaps by dependency and
  land after a clean full `bazel build //rust/...` + `bazel test //rust/...`.

## Migration Plan

1. Author the manifest-based `crates_vendor` rule in `third_party/BUILD.bazel` with the
   three annotations and no vestigial optional-crate `packages`.
2. `bazel run //third_party:crates_vendor -- --repin`; commit `third_party/crates/**`.
3. Behind the still-present `@rust_crates`, build a small proof set from the vendored
   universe — including one OpenSSL consumer and sysmon — to de-risk D5/OpenSSL.
4. Swap the load path in all 33 BUILD files (dependency order) to `//third_party/crates:defs.bzl`.
5. `bazel build //rust/...` and `bazel test //rust/...` green with no `@rust_crates` references.
6. Remove the `@rust_crates` `from_cargo` extension, its `use_repo`, and the three
   `annotation`/`spec` blocks from `MODULE.bazel`.
7. Confirm the `Splicing Cargo workspace for rust_crates` step no longer runs.

Rollback: revert the atomic PR; `@rust_crates` returns and vendored sources are ignored.

## Open Questions

- Local vs remote mode as the committed default if the vendored source weight is large
  (D4) — resolved to local unless size review says otherwise.
- Whether `crates_vendor` needs an explicit `cargo_config` equivalent for
  `//:.cargo/config.toml`, or the workspace default suffices.
- Whether to fold `rdp_connector_crates` into the same vendor pass or keep it separate —
  resolved: keep the connector universe separate and exact-pinned.
