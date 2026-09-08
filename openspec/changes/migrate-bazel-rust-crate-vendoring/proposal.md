# Change: Migrate Bazel Rust dependencies to a single locally vendored crate universe

## Why

Bazel resolves every Rust crate through crate_universe's `crates.from_cargo`
(`@rust_crates`) splicing. On every build that touches a Rust target, Bazel runs
a `Splicing Cargo workspace for rust_crates` step that takes 50s+ before any code
compiles — one of the slowest ways to manage Rust deps under Bazel. Moving to
**local vendoring** (`crates_vendor`, sources committed under `//third_party/crates`)
eliminates the splice and makes the dependency graph explicit and reviewable.

A pilot (vendoring the proto stack via a hand-picked `packages` list and swapping
`//rust/metric-proto`) proved the mechanics work but surfaced two hard constraints
that dictate the architecture:

1. **Duplicate-crate type clash.** A `crates_vendor` `packages` list creates a
   *second, disjoint* copy of each crate. To `rustc`, vendored `prost 0.13.5` and
   `@rust_crates` `prost 0.13.5` are different crates (separate rlibs → incompatible
   traits), even at the same version. Proto crates share prost-generated types across
   crate boundaries (e.g. `rust/otel/src/agent_forward/mod.rs:604` calls
   `serviceradar_metric_proto::pb::MetricBatch::decode` with `@rust_crates` `prost::Message`),
   so migrating one crate breaks its consumers. The universes cannot coexist.
2. **Splicing is all-or-nothing.** The splice runs as long as *any* target references
   `@rust_crates`, so a crate-by-crate rollout yields **zero** speedup until the last
   crate leaves and the extension is removed.

Together these mean the migration must be a **single-universe cutover**, not a curated
subset migrated incrementally.

## What Changes

- Replace the `crates.from_cargo` module extension (`@rust_crates`) with a single
  **manifest-based** `crates_vendor(manifests = ["//:Cargo.toml"], cargo_lockfile = "//:Cargo.lock")`
  in local mode, producing one vendored universe at `//third_party/crates`.
- Carry the three existing crate annotations into the vendor rule's `annotations`:
  `cri-api` (protoc), `openssl-sys` (perl wrapper + build env), and `openssl-src`
  (filegroups + `//third_party/rust_patches:openssl_src_runfiles_patch`, `-p1`).
- **OpenSSL portability (folded in):** eliminate OpenSSL where practical and vendor it
  where not.
  - flowgger's syslog TLS moves from the `openssl` crate to **rustls** (`ring`
    provider), removing `openssl` (0.10) + `openssl-src` from flowgger's default (`tls`)
    build graph. (`openssl` 0.10 remains *vendored* only because flowgger's optional,
    non-default `kafka-output`/`security` feature still pulls it; it is not compiled by
    the default build.)
  - libpq's remaining `openssl-sys` (via `pq-sys` bundled) uses the **vendored**
    (from-source) OpenSSL where system OpenSSL is absent. The system-OpenSSL `.bazelrc`
    overrides are **platform-scoped to `build:linux`** (not removed) — the Erlang/Elixir
    subtree also needs them and they are Linux paths. So Linux builds (local + CI) get
    system OpenSSL for Erlang/Elixir + Rust; macOS builds use the vendored Rust OpenSSL.
    See design D6.
  - Vendored OpenSSL is made to actually build under Bazel (the rules_rust #1519 gotcha,
    never previously exercised because the `.bazelrc` overrides always selected system
    OpenSSL): the `openssl_src_runfiles_patch` is updated for openssl-src 300.6.1 to fix
    `source_dir()` and strip Configure's `-no-canonical-prefixes`. Because crates_vendor
    local mode does not apply annotation `patches` on disk, `scripts/vendor.sh` re-applies
    the patch after vendoring.
- Drop the vestigial `libzetta`, `ironrdp-core`, and `ironrdp-pdu` root `packages`
  extras. The production RDP helper resolves its reviewed connector/CredSSP graph from
  the independent `rdp_connector_crates` universe, so duplicating IronRDP in the root
  vendor tree is both unused and a source of version drift.
- Swap `@rust_crates//:` → `//third_party/crates:` across **33** BUILD files (43 refs):
  both the `defs.bzl` loads and the direct alias labels (`@rust_crates//:serde`,
  `:tempfile`, `:zeroize`, `:async-nats`, `:serde_json-1.0.150`). No dep
  lists change — the vendored `defs.bzl` exposes the same `all_crate_deps`/`crate_deps`/
  `aliases` macros.
- **BREAKING (build graph):** land the load swaps and the extension removal together so
  no target is left referencing `@rust_crates`; a mixed state reintroduces the type clash.
- Remove `crates.from_cargo(name = "rust_crates")` + its `use_repo` and the three
  `crates.annotation` / `crates.spec` blocks from `MODULE.bazel` once no target references
  `@rust_crates`. This is the step that removes the splice.

Out of scope (separate follow-ups):
- The second, independent `rdp_connector_crates` extension
  (`//rust/rdp-connector-probe`, its own `Cargo.lock`) stays a distinct universe.
- No change to proto codegen (`cargo_build_script` + PROTOC) wiring, or to resolved crate
  versions beyond adding `openssl-sys`'s `vendored` feature (which pins openssl-src).

Also fixed (surfaced by the cutover):
- `pq-src` (libpq from source) now builds under Bazel on macOS — `pq_src_fortify_patch`
  re-asserts `-D_FORTIFY_SOURCE=0` past Bazel's `-U_FORTIFY_SOURCE`. `//rust/srql`
  (diesel + libpq + vendored OpenSSL) builds end-to-end.
- `rust/bmp-collector` converts from a cargo-in-genrule (which `cargo build`'d and failed
  under the Bazel sandbox) to a proper `rust_binary` on the vendored crates.
- **Integration tests move to a dedicated root-level subtree.** `srql_api_test` /
  `srql_comprehensive_test` wired the CNPG Postgres OCI image (AGE + TimescaleDB) as test
  `data` from inside `//rust/srql`, so `bazel build //rust/...` dragged in an entire
  Postgres image build. They move to **`//integration_tests/srql`** (a new
  `srql-integration-tests` crate, so `cargo test` still works) — heavy cross-cutting
  wiring lives there and nowhere else. `bazel build //rust/...` is now green with **zero**
  docker references.
- **CNPG image layers marked Linux-only.** The `{timescaledb,age,postgis}_extension_layer`
  genrules compile PG extensions by executing Linux ELF binaries from an extracted Debian
  rootfs — impossible on macOS. `target_compatible_with = ["@platforms//os:linux"]` makes
  Bazel *skip* them (and their dependents) off-Linux instead of failing. Their `sed -i`
  usage is also made portable (GNU/BSD/macOS).
- `scripts/vendor.sh` clears `third_party/crates` before vendoring (crates_vendor's own
  recursive delete intermittently aborts with `ENOTEMPTY` on macOS, leaving a half-deleted
  tree), re-applies both source patches, and records the exact root Cargo inputs in
  `third_party/crates/.serviceradar-vendor-inputs`. Native add-on release gates compare
  changed Rust package metadata with that index instead of looking for the removed root
  `from_cargo` extension in `MODULE.bazel.lock`.

## Impact

- Affected specs: `bazel-rust-crate-vendoring` (new capability).
- Affected code:
  - `MODULE.bazel` (remove `@rust_crates` extension, annotations, specs).
  - `third_party/BUILD.bazel` (the `crates_vendor` rule), `third_party/crates/**`
    (committed vendored sources + generated `defs.bzl`/`BUILD.bazel`).
  - 33 `rust/*/BUILD.bazel` files (plus 3 `third_party/rust_patches/*/BUILD.bazel`).
  - `scripts/vendor.sh` and `scripts/check-native-addon-version-bumps.sh` (vendor input
    integrity and native add-on release gates).
- Platform: unaffected — vendored crates are source, compiled on demand; the
  `extra_target_triples` (gnu/musl) selects are unchanged.
- Risk: `openssl-src` label/patch rewrite from `@rust_crates__openssl-src-*` to the
  vendored repo. See `design.md`.
