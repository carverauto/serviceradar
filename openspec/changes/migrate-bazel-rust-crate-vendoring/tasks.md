## 1. Author the manifest-based vendor rule

- [x] 1.1 Replace the pilot `crates_vendor` in `third_party/BUILD.bazel` with a
  manifest-based rule: `mode = "local"`, `manifests = ["//:Cargo.toml"]`,
  `cargo_lockfile = "//:Cargo.lock"`, `vendor_path = "crates"`,
  `repository_name = "rust_crates"`, `tags = ["manual"]`.
- [x] 1.2 Port the three annotations into `annotations = {…}` (drop `repositories`):
  `cri-api` (protoc), `openssl-sys` (perl-wrapper + build env), `openssl-src`
  (filegroups + patch).
- [x] 1.3 Rewrite the openssl-src runfiles/readme label references from
  `@rust_crates__openssl-src-*//:…` to the vendored crate's labels
  (`//third_party/crates/openssl-src-300.6.1-3.6.3:…`; `+`→`-` sanitized).
- [x] 1.4 Drop the unused `libzetta`, `ironrdp-core`, and `ironrdp-pdu` root `packages`
  extras. The shipped RDP helper resolves IronRDP from the exact-pinned, independent
  `rdp_connector_crates` universe instead of duplicating that graph in the root vendor.
- [x] 1.5 Add `.cargo/config.toml` to the root `exports_files(...)` and pass
  `cargo_config = "//:.cargo/config.toml"`.
- [x] 1.6 Fix `scripts/vendor.sh` (`//thirdparty`→`//third_party`) and make it the
  vendor + post-patch entrypoint (see §3).

## 2. Generate and commit the vendored universe

- [x] 2.1 `bazel run //third_party:crates_vendor` — 780 crates vendored to
  `third_party/crates/` (~1 GB local mode).
- [x] 2.2 Verify the vendored `openssl-src-300.6.1-3.6.3` directory name matches the
  `openssl-sys` annotation labels.
- [ ] 2.3 Commit `third_party/crates/**`. If the ~1 GB local weight is unacceptable,
  switch to `mode = "remote"` (design D4).
- [x] 2.4 Record the root Cargo manifest, lockfile, and all workspace member manifest
  hashes in `third_party/crates/.serviceradar-vendor-inputs`; make the native add-on
  version guard validate this index while retaining `MODULE.bazel.lock` validation for
  the independent RDP connector universe.

## 3. Drop OpenSSL for rustls where possible; vendor it where not (openssl portability)

- [x] 3.1 flowgger → rustls: rewrite `input/tls` + `output/tls_output` (+ coroutine
  `tlsco_input`) from OpenSSL (`SslAcceptor`/`SslConnector`) to `rustls`
  (`ServerConfig`/`ClientConfig` + `StreamOwned`, `ring` provider); drop the `openssl`
  dep. Removes the `openssl` (0.10) crate **and** `openssl-src` from flowgger. Builds
  green via cargo (openssl-free).
- [x] 3.2 libpq (srql): add `openssl-sys = { features = ["vendored"] }` so `pq-sys`
  bundled static-links a from-source OpenSSL; drop the system-OpenSSL `.bazelrc`
  overrides (`OPENSSL_DIR`/`LIB_DIR`/`INCLUDE_DIR`/`NO_VENDOR`/`NO_PKG_CONFIG`).
- [x] 3.3 Make vendored OpenSSL build under Bazel (rules_rust #1519 gotcha, never
  previously exercised since system OpenSSL always won). Update
  `third_party/rust_patches/openssl_src_runfiles_patch` for openssl-src 300.6.1: (a)
  `source_dir()` honors `RULES_RUST_OPENSSL_SRC_DIR` (the crate's baked
  `CARGO_MANIFEST_DIR` is a stale sandbox path); (b) strip `-no-canonical-prefixes`
  from Configure. Add the `openssl_src_version_marker` filegroup + set
  `RULES_RUST_OPENSSL_SRC_DIR` = `$(location …:openssl_src_version_marker)`.
- [x] 3.4 crates_vendor **local mode does not apply annotation `patches`** to on-disk
  sources → `scripts/vendor.sh` re-applies the openssl-src patch after the vendor run
  (idempotent). Verified: `//third_party/crates/openssl-sys-0.9.116:openssl_sys` builds
  from-source vendored OpenSSL on macOS.
- [x] 3.5 `pq-src` (libpq 18.3 from source) macOS build fix: Bazel's cc_wrapper appends
  `-U_FORTIFY_SOURCE` to `$CFLAGS`, which cc-rs applies **last** (lib.rs:2064), overriding
  pq-src's `-D_FORTIFY_SOURCE=0` and re-enabling macOS's fortify `strlcat`/`strlcpy`
  builtins that conflict with libpq's bundled copies. `pq_src_fortify_patch` re-asserts
  `-D_FORTIFY_SOURCE=0` at the end of `$CFLAGS` on macOS (applied by `scripts/vendor.sh`,
  like the openssl-src patch). Verified: `//third_party/crates/pq-src-*:pq_src` and
  `//rust/srql:srql_lib` (diesel + libpq + vendored openssl) build green on macOS.

## 4. Atomic cutover of BUILD files

- [x] 4.1 Swap `@rust_crates//:` → `//third_party/crates:` across all Rust BUILD files —
  covers both `load("…/:defs.bzl", …)` and direct alias labels (`@rust_crates//:serde`,
  `:tempfile`, `:zeroize`, `:async-nats`, `:serde_json-1.0.150`). 43
  refs across 33 files (incl. `rust/rdp-adapter` + 3 `third_party/rust_patches/*`). Dep
  lists unchanged.
- [x] 4.2 Representative build green: `//rust/metric-proto`, `//rust/kvutil`,
  `//rust/flowgger`, `//rust/addon-sdk` (proto / all_crate_deps / rustls / path-dep
  cluster). The prost-type clash is gone (single universe).
- [x] 4.3 Verify **no** remaining `@rust_crates` references in rust/ + third_party BUILD files.

## 5. Remove the splice

- [x] 5.1 Delete the `crates` `use_extension` + `from_cargo(name = "rust_crates")` +
  `use_repo` + the three `annotation`/three `spec` blocks from `MODULE.bazel`.
- [x] 5.2 Confirm the `Splicing Cargo workspace for rust_crates` step no longer runs on a
  clean build (verified: splice count 0, build green).
- [x] 5.3 Leave the separate `rdp_connector_crates` extension intact.

## 6. Validation

- [x] 6.1 Representative `bazel build` green with the splice gone (§4.2, §5.2).
- [ ] 6.2 Full `bazel build //rust/...` + `bazel test //rust/...` on **Linux CI** (macOS
  cannot build openssl/libpq-consuming targets — §3.5 + pre-existing constraint).
- [ ] 6.3 Cross-platform config-settings (gnu/musl) still resolve.
- [ ] 6.4 Run `openspec validate migrate-bazel-rust-crate-vendoring --strict`.
