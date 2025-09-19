# Bazel Implementation Plan

## 1. Goals & Success Criteria
- Deliver a reproducible, hermetic build and test system for the entire monorepo using Bazel.
- Reduce CI wall-clock time by leveraging Bazel caching and BuildBuddy remote execution.
- Replace bespoke language-specific build scripts with Bazel targets that cover local dev, packaging, and release workflows.
- Achieve green Bazel builds for all primary languages (Go, Rust, Node/TypeScript, OCaml when adopted) and supporting assets (proto, Docker/OCI images, packages).
- Sunset redundant GitHub Actions workflows in favor of Bazel-driven CI.

## 2. Scope & Assumptions
- Languages in scope: Go, Rust, Node/TypeScript (Next.js), OCaml (planned), plus protobuf/gRPC assets.
- Artefacts in scope: binaries, libraries, container images, Debian/RPM packages, Helm/K8s manifests generation, integration tests.
- CI target: GitHub Actions using BuildBuddy for remote cache/execution.
- Bazel version management via Bazelisk; repository will pin Bazel version through `.bazelversion`.
- No large-scale refactors expected during initial migration; code layout stays largely intact.

## 3. Prerequisites & Tooling Setup
1. **Team enablement**
   - Identify Bazel champions across language verticals; schedule onboarding sessions.
   - Share key references: <https://bazel.build/start/go>, <https://github.com/bazelbuild/examples/tree/main/go-tutorial>, <https://github.com/bazelbuild/examples/tree/main/rust-examples>.
   - Create internal "Bazel 101" doc focusing on repo norms.
2. **Environment tooling**
   - [x] Add Bazelisk wrapper under `tools/` (developers use Homebrew-installed Bazelisk) and distribute instructions.
   - [x] Create `.bazelversion` to pin the chosen Bazel release.
   - [x] Add `.bazelrc` with shared options (build/test flags, remote cache stubs, platform defaults).
   - [x] Introduce `tools/bazel/` scripts for common developer flows (e.g., `bazel run //tools:bazel-test-all`).
3. **Repository hygiene**
   - Audit existing build artifacts under `_build/`, `target/`, `dist/`, `release-artifacts/` and document what Bazel needs to reproduce.
   - Freeze current CI workflows to avoid churn during migration window.

## 4. Phase 1 – Bootstrap Bazel Skeleton (Week 1)
1. **Initialize workspace**
   - [x] Create root `WORKSPACE.bazel` and `MODULE.bazel` (bzlmod).
   - [x] Declare Bazel rulesets (`rules_go` + Gazelle, `rules_rust`, `rules_nodejs`, `rules_proto`, `rules_oci`, `rules_pkg`, `aspect_rules_js`).
   - [x] Register shared toolchains (Go SDK via `go_sdk.from_file`, Rust 1.82 toolchains, Node.js 22.13.1 for darwin/linux on amd64 & arm64).
   - [x] Pin `rules_ocaml` 3.0.0.beta.1 via `archive_override`; plan follow-up to register toolchains and OCaml toolchains once workflow is defined.
   - [x] Mirror `tools_opam` 1.0.0.beta.1 and its required auxiliary modules (`obazl_tools_cc`, `findlibc`, `runfiles`, `xdgc`, `gopt`, `liblogc`, `makeheaders`, `sfsexp`, `uthash`, `semverc`, `cwalk` vendored from commit e98d23f; dev-only dependency `unity` deferred).
   - [x] Configure tools_opam module extension for srql packages; register ocamlsdk toolchains for OCaml 5.1.0.
   - [x] Model external binary dependencies using `http_file` (`timeplus`, `nats-server`, etc.).
2. **Seed minimal BUILD targets**
   - [x] Add `//docs:lint` or placeholder target to validate workspace loads.
   - [x] Add `//proto:compile` using `rules_proto` to confirm toolchains.
3. **Automation**
   - [x] Add CI safety net: GitHub Action job running `bazel build //docs:lint` to ensure early detection of regressions.

## 5. Phase 2 – Language Foundations (Weeks 2–4)
### 5.1 Go
- [x] Run Gazelle across `cmd/`, `internal/`, `pkg/`, `poller/` directories to seed Bazel targets.
- [x] Define `go_library`, `go_binary`, and `go_test` targets mirroring current module boundaries (CLI builds under Bazel, `pkg/logger:logger_test` passes).
- [x] Retire the legacy Go SRQL implementation (`pkg/srql`) in favor of the OCaml version so future work centers on `ocaml/srql` only.
- [x] Establish `//proto` → Go code generation with `rules_proto` + `rules_go` plugin (root `proto` and `proto/discovery` now use `go_proto_library`, with checked-in Go stubs kept only for non-Bazel workflows).
- [x] Validate with `bazel test //cmd/... //internal/...`.

### 5.2 Rust
- [x] Introduce Bazel-managed Rust crate dependencies (via `crate_universe`) to mirror the Cargo workspace.
- [x] Define initial `rust_library`/`rust_test` targets (`//rust/kvutil`) as the first Bazelized crate.
- Configure incremental compilation cache dirs for deterministic builds.
- [x] Validate with `bazel test //rust/...`.

### 5.3 OCaml (deferred)
- `tools_opam` fork now rewrites `ppx_deriving` outputs to avoid target name collisions and vendors the extension locally for reproducible fetches. The same override now normalizes `digestif` and its subpackages so the generated repos expose usable archives/plugins.
- `//ocaml/srql/BUILD.bazel` defines modules, the `srql_translator` library namespace shim, binaries, and Alcotest-based smoke tests; alias module lives under `ocaml/srql/bazel/` to avoid interfering with dune.
- `bazel build //ocaml/srql:srql_translator` passes locally. `Proton_client` temporarily substitutes parameters inline (sanitizing values) until the upstream Proton driver exposes prepared statements.
- Validate with language-specific `bazel test` invocations; `bazel test //ocaml/srql:test_json_conv` is green.

### 5.4 Node/TypeScript (Next.js)
- [x] Configure `rules_nodejs` + `aspect_rules_js` with `npm_translate_lock` (driven by `web/pnpm-lock.yaml`).
- [x] Add `ts_project`/`next_js_binary` targets to reproduce the Next.js build (see `//web:typecheck` and `//web:next_js_binary`).
- [x] Ensure static assets pipeline (`web/`, `pkg/`) compiles under Bazel (Next.js standalone build succeeds and `//pkg/core/api/web:files` mirrors the bundle).
    - [x] Update Go packaging/release workflows to consume `//pkg/core/api/web:files` instead of invoking npm scripts directly.

### 5.5 Shared Assets
- Proto/gRPC: centralize under `proto/BUILD.bazel`, generate Go/Rust/TypeScript stubs.
- Configuration schemas: move toward runtime-fetched configuration; represent generated code or defaults as Bazel targets.

## 6. Phase 3 – Packaging & Artifact Strategy (Weeks 5–6)
- ✅ Core component packaged via `//packaging/core:core` (`pkg_tar` + `pkg_deb`), replacing goreleaser configs.
- RPM publishing remains pending a Linux rpmbuild runner (to tackle alongside remote execution setup).
- Containers: adopt `rules_oci` to replace Dockerfiles for services under `cmd/services`.
- Debian/RPM: use `rules_pkg` to encode package metadata previously handled by `setup-package.sh`.
- Helm charts/K8s: evaluate templating approach; either keep separate or use Bazel to package manifests.
- Binary distribution: create `pkg_tar`/`pkg_zip` targets for release artifacts.
- Validate artifact parity against legacy scripts.

## 7. Phase 4 – Testing & Integration (Weeks 6–7)
- Recreate unit, integration, and end-to-end tests as Bazel targets (`go_test`, `rust_test`, `py_test`, custom `sh_test`).
- For services requiring dependent infrastructure (Postgres, ClickHouse, Timeplus):
  - Use `rules_docker` + `oci_image` to spin hermetic containers.
  - Encapsulate orchestration in `bazel test` targets with `docker_run` or `rules_k8s`.
- Formalize golden data fixtures under Bazel-managed runfiles.
- Enable coverage collection via `bazel coverage` with language-specific flags.

## 8. Phase 5 – CI/CD Modernization (Weeks 8–9)
1. **BuildBuddy integration**
   - Create BuildBuddy account/project; obtain remote cache/execution endpoints.
   - Configure `.bazelrc` `--remote_cache`, `--remote_executor`, and `--bes_backend` entries toggled by `--config=ci`.
   - Add developer opt-in remote caching config guarded by environment variables.
   - Stand up a Bazel remote execution/cache cluster in Kubernetes (reuse existing platform observability).
2. **GitHub Actions rewrite**
   - Replace per-language workflows with unified `bazel test //...` pipeline (with matrix for platforms if needed).
   - Add presubmit targets (lint, build, test) using Bazel query to scope changed packages.
   - Integrate BuildBuddy GitHub checks for build/test artifacts.
3. **Release automation**
   - Migrate release pipelines (`release.yml`, `docker-build.yml`) to call Bazel targets (e.g., `bazel build //...:image`, `bazel build //...:deb`).
   - Publish artifacts using `bazel run` wrappers for registry uploads.

## 9. Phase 6 – Adoption & Hardening (Weeks 10–12)
- Document developer workflows: local builds, incremental tests, remote cache opt-in, debugging failing targets.
- Establish pre-submit Bazel lint rules (buildifier, buildozer) and formatting CI.
- Add Bazel metrics dashboard via BuildBuddy for cache hit/miss analysis.
- Run parallel legacy CI for one milestone sprint; once parity achieved, decommission old workflows.
- Capture lessons learned; plan follow-up improvements (e.g., Remote Execution, distributed builds).

## 10. Risk Management & Mitigations
- **Learning curve**: mitigate via pair sessions, Bazel brown bags, office hours.
- **Rule ecosystem maturity**: vet community rules (`rules_ocaml`, `rules_nodejs`) early; be ready to pin forks or contribute patches.
- **Third-party binaries**: ensure licenses allow redistribution; fallback to container images if Bazel packaging proves complex.
- **Flaky tests**: invest in hermetic test infrastructure; avoid implicit dependencies and network calls.
- **Monorepo churn**: coordinate Bazel onboarding windows with feature freeze periods for critical services.

## 11. Deliverables & Checkpoints
- ✅ `WORKSPACE`/`MODULE.bazel`, `.bazelrc`, `.bazelversion`, Bazelisk integration.
- ✅ Minimal builds for each language directory with CI smoke tests.
- ✅ Artifact parity report vs. legacy system (hash comparison where feasible).
- ✅ BuildBuddy remote cache functioning in CI and opt-in locally.
- ✅ Updated GitHub Actions pipeline using Bazel.
- ✅ Migration retrospective and follow-up backlog.

## 12. Communication & Tracking
- Create Bazel migration epic in project tracker (Jira/Linear) with per-phase stories.
- Hold weekly sync focused on blockers; keep live migration checklist in `docs/bazel-migration.md`.
- Announce major milestones to engineering via Slack/email; maintain change log.

## 13. Long-Term Enhancements (Post-Migration)
- Explore Remote Execution on BuildBuddy to parallelize heavy builds/tests.
- Introduce Bazel Query/Graph tooling for impacted target calculation in CI (change-based testing).
- Automate dependency updates via Bazel module extensions / Renovate integration.
- Consider splitting large integration tests into hermetic shards using Bazel `test_suites`.
- Evaluate Starlark macros for common service patterns (binary + container + package).
