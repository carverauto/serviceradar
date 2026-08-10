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

## 5c. Bump the pinned toolchain (exercises the seam from 5b)
- [x] 5c.1 Nightly `2026-05-31` -> **`2026-08-05`** (rustc 1.98.0-nightly -> 1.99.0-nightly), all four component sha256s re-pinned from the dated rustup-dist manifest
- [x] 5c.2 bpf-linker `0.10.3` -> **`0.10.4`**. 0.10.4 ported its build to Bazel and switched release assets from `.tar.gz` to `.tar.zst`, so the archive extension became an overridable tag attribute rather than a hardcoded suffix. Side effect: the binary drops 653 MB -> 101 MB, because debuginfo moved to a separate asset
- [x] 5c.3 **LLVM is the ceiling, not the date.** rustc emits bitcode bpf-linker consumes, and bitcode is backward- but not forward-compatible. bpf-linker 0.10.4 bundles LLVM 22.1.7; rust-lang/rust#158734 moved rustc to LLVM 23 on 2026-08-05. `nightly-2026-08-05` is LLVM 22.1.8 — the last usable one. Verified the boundary rather than assuming it: `nightly-2026-08-08` is LLVM 23.1.0. Recorded at the pin and in the ruleset README; going further needs an LLVM 23 bpf-linker upstream
- [x] 5c.4 Vendor tree regenerated against the new `rust-src`: 56 crates before and after, **15 version changes** (addr2line 0.25.1->0.27.1, gimli 0.32.3->0.34.0, object 0.37.3->0.39.1, libc, memchr, miniz_oxide, moto-rt, rand, rand_core, rustc-demangle, rustc-literal-escaper, unwinding, wasip2, wasip3, dlmalloc). All std-workspace `-Z build-std` deps; no aya dependency moved and `Cargo.lock` is unchanged
- [x] 5c.5 Vendor README corrected. The documented recipe could not work: the crate is not a workspace member and has no `[workspace]` table (the rule appends one at build time), so `cargo vendor` aborts; and `cargo vendor` manages its destination, so aiming it at the vendor directory deletes that package's own `BUILD.bazel` and README. Recipe now stages and swaps, and warns that a version change reads as hundreds of modified files because `cargo vendor` omits the version from single-version directory names
- [x] 5c.6 Object rebuilt: sha256 `a0a767cd…3be5`, 63,320 bytes (was `4b0addd0…d69995`, 63,160), valid `ELF eBPF`, and identical inside the bundle. Bytes differ by design — a new compiler — so byte-identity is not the acceptance test here
- [x] 5c.7 **Version-gate gap closed.** `path_belongs_to_addon` claimed only `addons/netprobe/*` and `rust/netprobe/*`, but the toolchain pins and the vendor tree determine the shipped object's bytes. A nightly bump would have changed the artifact under an unchanged version — the exact false negative the gate exists to prevent. Added `third_party/rules_aya_ebpf/*` and `third_party/netprobe_ebpf_vendor/*`

- [x] 5c.8 **Pins moved to the root module, killing a cross-repo coupling before it could exist.** The vendor tree is a function of the nightly (`-Z build-std` resolves the std workspace's crates.io deps), so inheriting `DEFAULT_NIGHTLY_DATE` would put one half of that pair under the ruleset's control — and once the ruleset lives in its own repo, bumping its default would invalidate this repo's vendor tree from the outside. `MODULE.bazel` now pins the nightly and bpf-linker explicitly, exactly as it already pins OTP and Elixir rather than taking `DEFAULT_*`. Verified the override is load-bearing, not decoration: changing the root's `date` made Bazel fetch `dist/2026-07-01/` and fail on checksum, and restoring it reproduced the object byte-for-byte (`a0a767cd…3be5`). The ruleset's `extension_metadata` no longer claims `root_module_direct_deps`, since the toolchain hub is its own plumbing and a consumer using the extension only to move pins should not have to `use_repo` a repository it never names

## 6. Follow-up (tracked, not in this change)
- [ ] 6.1 Multi-arch eBPF (`--cfg bpf_target_arch` arm64) — separate change. Now a row in `_EXEC_PLATFORMS` plus an `ebpf_object(bpf_target_arch = ...)`, not a genrule rewrite
- [ ] 6.2 Revisit H1 (pure rules_rust `rust_binary` + build-std) when upstream tier-3 build-std support matures
- [ ] 6.3 Bump the nightly pin. Not a version-string edit: `-Z build-std` resolves the std workspace's own crates.io deps, so the ~29 MB vendor tree must be regenerated against the matching `rust-src` in the same commit
- [ ] 6.4 Register a darwin execution platform. Upstream publishes rustup-dist components and `bpf-linker` for `{x86_64,aarch64}-apple-darwin`, so a Mac can cross-compile the object without RBE — a row in `_EXEC_PLATFORMS` plus its sha256s
- [x] 6.5 **Extracted.** The ruleset now lives at <https://github.com/marvin-hansen/rules_aya_ebpf> and is consumed from a sibling checkout via `local_path_override(path = "../rules_aya_ebpf")`; swap that for a `git_override`/`archive_override` once a commit is released. Nothing in this repository moved with it — the toolchain pins stay in `MODULE.bazel` (5c.8), so which override is in use cannot change what we compile. Verified the object is byte-identical when built from the sibling checkout (`a0a767cd…3be5`)
  - Gate paths follow: `third_party/rules_aya_ebpf/*` drops out of the version-bump gate and the verifier workflow, since no path can watch an external module. What the gates exist to catch is unaffected — a nightly bump moves the pins in `MODULE.bazel` (which the verifier watches) and the vendor tree (which the version gate watches). A ruleset upgrade that changes rule behaviour is a callsite fix like any other dependency bump, not something to gate on
