## 1. Spike: pick the hermetic bpf-linker approach (blocking) — DONE 2026-06-01
- [x] 1.1 Determine the nightly date compatible with aya-ebpf 0.1.1 / aya-build 0.1.3 + `-Z build-std=core` for `bpfel-unknown-none` → **`nightly/2026-05-31`** (rustc 1.98.0-nightly), validated on the test box
- [x] 1.2 Evaluate Decision-3 options → bpf-linker `0.10.3` statically bundles LLVM (no dynamic LLVM); upstream publishes a fully-static `x86_64-unknown-linux-musl` release binary → **pinned upstream prebuilt** wins (no hermetic LLVM / crate_universe needed)
- [x] 1.3 Record the decision + pins in `design.md` (nightly 2026-05-31; bpf-linker v0.10.3 musl sha256 `0fa4645d…6262c`; arm64 musl `02f71967…04d1`)
- [x] 1.4 Proven out-of-Bazel: the box's nightly+rust-src+bpf-linker 0.10.3 produced a valid `ELF eBPF` object (`/tmp/netprobe_ebpf.o`, 79,952 bytes)

## 2. Hermetic toolchain inputs (MODULE.bazel) — rustup-dist http_archives + offline vendor
- [x] 2.1 `http_archive` the nightly `rustc`/`cargo`/`rust-std-x86_64-gnu` components (2026-05-31, pinned sha256) — `@netprobe_ebpf_{rustc,cargo,rust_std}`, build_file exposes `install.sh` + `:all`; stable `1.93.0` untouched
- [x] 2.2 `http_archive` `rust-src-nightly.tar.xz` (2026-05-31) — `@netprobe_ebpf_rust_src`
- [x] 2.3 `http_archive` `bpf-linker-x86_64-unknown-linux-musl.tar.gz` v0.10.3 — `@netprobe_ebpf_bpf_linker` (single root-level `bpf-linker`, sha256 verified)
- [x] 2.4 **Vendored the eBPF crate deps + std build-std deps**: `cargo vendor --sync <rust-src>/library/Cargo.toml` → `rust/netprobe/ebpf/vendor/` (56 crates, 29M — incl `rustc-literal-escaper`/`libc`/`object`/`hashbrown` that `-Z build-std` needs). Recipe PROVEN hermetically on the box: assembled nightly sysroot from the pinned component tarballs + offline vendored build → valid `ELF eBPF` object, 79952 bytes (size-identical to the rustup build). ⚠️ 29M vendor commit — flagged for review (trim/relocate candidate).
- [ ] 2.5 `use_repo(...)` the new repos; confirm each resolves on linux-amd64 (RBE exec platform)

## 3. eBPF build target (replace the host-cargo genrule)
- [x] 3.1 Rewrote `//rust/netprobe/ebpf:netprobe_ebpf_object` as a hermetic genrule consuming the `@netprobe_ebpf_*` toolchain + linker + vendor
- [x] 3.2 `build-ebpf-object.sh` rewritten: assembles a scratch sysroot via each component `install.sh`, sets `PATH`/`CARGO_HOME`/`RUSTC`/`CARGO_TARGET_BPFEL_UNKNOWN_NONE_LINKER`/`RUSTFLAGS` from the pinned inputs only, builds `--offline --locked --target bpfel-unknown-none -Z build-std=core --release`
- [x] 3.3 Same output label + filename (`netprobe_ebpf.o`); `addon_inventory.bzl` consumer unchanged (verified: only consumer is the bundle data entry)
- [x] 3.4 Removed host-PATH probing entirely; the script takes explicit `--install`/`--bpf-linker`/`--vendor`/`--crate` inputs
- [x] 3.5 `target_compatible_with = linux`; no external consumers of `netprobe_ebpf_srcs`

## 4. Verify hermeticity across all lanes
- [x] 4.1/4.2 `bazel build --config=ci //rust/netprobe/ebpf:netprobe_ebpf_object` builds on **carverauto RBE** (`1 remote`, linux worker) → valid `ELF eBPF`, 79952 bytes (size-identical to the rustup + box builds). The exact action that failed with "cargo is required" now succeeds remotely.
- [x] 4.2b **Second blocker found + fixed**: `netprobe_addon_bundle` assembly genrule rejected `addons/netprobe/addon.yaml` — the dependency-free fallback parser in `assemble_addon_bundle.py` didn't strip inline `#` comments (masked because the eBPF genrule failed first; the Go gate validator strips them, so `build_gates_test` passed). Hardened `_strip_inline_comment` in the fallback parser (matches YAML + the Go validator). Local parse test green.
- [x] 4.3 `bazel build --config=ci //build/native_addons:netprobe_addon_bundle.linux.amd64.tar.gz` on RBE → **assembles successfully**; tarball contains `netprobe_ebpf.o` (valid 79952-byte eBPF ELF) + `serviceradar-netprobe` + `serviceradar-netprobe.service` + `addon.yaml` + `config.schema.json`
- [x] 4.6 Vendor committed as the extracted `rust/netprobe/ebpf/vendor/` tree (56 crates, ~29M), consumed via `--vendor`. (A compressed-tarball variant was tried and reverted in favor of the transparent extracted tree.)
- [ ] 4.4 `netprobe-kernel-*` verifier lane stays green (object loads on 5.8 / 5.15 / 6.x; refusal on 5.4)
- [ ] 4.5 Determinism check: rebuilds produce a stable object (verifier and bundle agree)

## 5. Wire into the publish pipeline + ship
- [ ] 5.1 Confirm `scripts/ci/netprobe-ebpf-verify.sh` no longer needs host nightly (uses the Bazel target)
- [ ] 5.2 Re-dispatch `Publish Native Add-ons`; confirm `sha-<HEAD>` Forgejo release + `serviceradar-native-addon-index.json` with the netprobe entry
- [ ] 5.3 Update BUILD deps / bazel test targets (`bazel test //build/native_addons:build_gates_test` and any new toolchain targets)
- [ ] 5.4 Docs: note the hermetic eBPF build + pins in build docs

## 5b. Repackage as a ruleset with a real toolchain (Decision 6)
- [x] 5b.1 `//third_party/rules_aya_ebpf`: vendored Bazel module with `toolchain_type`, `aya_ebpf_toolchain`, `ebpf_object`, and a `bzlmod` extension that fetches the pins and declares the toolchains. Registered in `//.bazelignore` alongside `rules_erlang` / `rules_elixir`
- [x] 5b.2 `MODULE.bazel`: the 53-line `netprobe_ebpf_*` `http_archive` block replaced by `bazel_dep` + `local_path_override` (1,961 → 1,908 lines). Pins overridable from the root via the `nightly` / `bpf_linker` tag classes
- [x] 5b.3 `build-ebpf-object.sh` **deleted**; the action script is generated by the rule, so every input is a typed attribute rather than a `$(location ...)` string. Closes the repo's "no shell scripts" hard rule for this path
- [x] 5b.4 Linux constraint moved onto the correct axis: `exec_compatible_with = [linux, x86_64]` on the `toolchain()`, artifact-level `target_compatible_with = [linux]` on the target. `bpf_target_arch` is now a rule attribute — the seam for 6.1
- [x] 5b.5 Byte-identity verified: sha256 `4b0addd0…d69995`, 63,160 bytes, unchanged before/after, and identical inside `netprobe_addon_bundle.linux.amd64.tar.gz`
- [x] 5b.6 Darwin behaviour verified: wildcard build skips the target silently; an explicit request reports the unsatisfied `os:linux` constraint; darwin execution platforms are rejected by toolchain resolution (`mismatching values: linux, x86_64`); an unresolved toolchain fails with an authored message
- [x] 5b.7 `bazel test --config=ci //build/native_addons:build_gates_test` — all 8 targets pass. `addons/netprobe/addon.yaml` + `NETPROBE_VERSION` bumped 0.2.27 → 0.2.28 (the gate claims `rust/netprobe/*`, so a build-only edit still demands a bump)

## 6. Follow-up (tracked, not in this change)
- [ ] 6.1 Multi-arch eBPF (`--cfg bpf_target_arch` arm64) — separate change. Now a row in `_EXEC_PLATFORMS` plus an `ebpf_object(bpf_target_arch = ...)`, not a genrule rewrite
- [ ] 6.2 Revisit H1 (pure rules_rust `rust_binary` + build-std) when upstream tier-3 build-std support matures
- [ ] 6.3 Bump the nightly pin. Not a version-string edit: `-Z build-std` resolves the std workspace's own crates.io deps, so the ~29 MB vendor tree must be regenerated against the matching `rust-src` in the same commit
- [ ] 6.4 Register a darwin execution platform. Upstream publishes rustup-dist components and `bpf-linker` for `{x86_64,aarch64}-apple-darwin`, so a Mac can cross-compile the object without RBE — a row in `_EXEC_PLATFORMS` plus its sha256s
- [ ] 6.5 Extract `//third_party/rules_aya_ebpf` to its own repository and swap `local_path_override` for a version dep
