# Repository Layout Inventory Matrix

## Scope Basis
This matrix is derived from issue #2851 requests and current repo root inspection.

## In Scope (Source -> Target)
| Source | Target | Risk | Coupling Signals | Notes / Blockers |
|---|---|---|---|---|
| `cmd/` | `go/cmd/` (Go) and `rust/` (Rust subtrees currently under `cmd/`) | High | ~117 path references across Make/Bazel + docker image targets | Requires coordinated Bazel label rewrite and Makefile path updates. Contains mixed-language content. |
| `pkg/` | `go/pkg/` | High | ~180 path references; pervasive Bazel deps (`//pkg/...`) | Largest blast radius for import paths, Bazel labels, and aliases. |
| `internal/` | `go/internal/` | High | High reference density (`//internal/...` and implicit `internal` usage) | Must preserve Go `internal` package import semantics during move. |
| `web-ng/` | `elixir/web-ng/` | High | Referenced by Make targets and release/build flows | Requires Mix, Docker/Bazel image, docs, and CI path updates. |
| `age/` | `database/age/` | Low | Minimal path coupling observed | Mostly asset relocation with docs/build path adjustments. |
| `timescaledb/` | `database/timescaledb/` | Low | Minimal path coupling observed | Similar to `age/`; suitable for early wave. |
| `snmp/` | `contrib/snmp/` | Medium | Low direct root-level coupling, but domain usage uncertainty | Validate runtime/docs expectations before move. |
| `plugins/` | `contrib/plugins/` | Medium | Low direct root-level coupling | Confirm plugin loader and docs references first. |
| `packaging/` | `build/packaging/` | Medium | Indirect coupling via scripts/release flow | Coordinate with release automation and package scripts. |
| `release/` | `build/release/` (selected assets) | Medium | ~10 references in Make/release flows | Likely phased/partial move to avoid breaking release tooling. |
| `alias/` | `build/alias/` (or retire) | High | Bazel alias package currently maps many `//pkg/...` labels | Do not move until Go/Bazel label rewrite strategy is finalized. |
| `third_party/` | Conditional (`build/third_party/` only if compatible) | High | ~44 direct Bazel/module references | Keep at root unless compatibility proof is explicit. |
| `scripts/` | keep root or split (`build/scripts`, `tools/scripts`) after audit | Medium | ~37 Make/workflow references | Requires usage audit to avoid deleting operational scripts. |

## Out of Scope / Explicit Exclusions
These directories are not part of repo-layout cleanup execution unless separately proposed:
- VCS/system dirs: `.git/`, `.cache/`, `.gocache/`, `.gomodcache/`
- Local/dev state: `.local-dev/`, `.local-dev-certs/`, `logs/`, `target/`
- External/editor state: `.agent/`, `.claude/`, `.gemini/`, `.beads/`, `.buildbuddy/`, `.bazelbsp/`

## Proposed Wave Order
1. Wave 1 (Low risk): `age/`, `timescaledb/`
2. Wave 2 (Medium): `snmp/`, `plugins/`, early `scripts/` classification only
3. Wave 3 (High): `cmd/`, `pkg/`, `internal/` (coordinated Go+Bazel rewrite)
4. Wave 4 (High): `web-ng/` consolidation under `elixir/`
5. Wave 5 (Conditional): `packaging/` + `release/` moves into `build/`, then evaluate `alias/` and `third_party/`

## Execution Status
- Completed (2026-02-20): Wave 1 directory moves
  - `age/` -> `database/age/`
  - `timescaledb/` -> `database/timescaledb/`
- Updated Bazel label references in `docker/images/BUILD.bazel`:
  - `//age:source_tree` -> `//database/age:source_tree`
  - `//timescaledb:source_tree` -> `//database/timescaledb:source_tree`
- Validation performed:
  - `bazel query \"set(//database/age:source_tree //database/timescaledb:source_tree //docker/images:age_extension_layer //docker/images:timescaledb_extension_layer)\"`
  - `bazel build //database/age:source_tree //database/timescaledb:source_tree`
- Completed (2026-02-20): Wave 2 directory moves
  - `snmp/` -> `contrib/snmp/`
  - `plugins/` -> `contrib/plugins/`
- Follow-up adjustments:
  - Updated plugin module path:
    - `github.com/carverauto/serviceradar/plugins/go/dusk-checker` -> `github.com/carverauto/serviceradar/contrib/plugins/go/dusk-checker`
- Validation performed:
  - `go list ./...` in `contrib/plugins/go/dusk-checker`
  - Verified no remaining root `snmp/` or `plugins/` directories
- Completed (2026-02-20): Wave 3 prep slice (`internal/` only)
  - `internal/` -> `go/internal/`
- Follow-up adjustments:
  - Updated import path:
    - `github.com/carverauto/serviceradar/internal/fastsum` -> `github.com/carverauto/serviceradar/go/internal/fastsum`
  - Updated Bazel deps:
    - `//internal/fastsum` -> `//go/internal/fastsum`
- Validation performed:
  - `go test ./go/internal/fastsum`
  - `bazel build //go/internal/fastsum:fastsum //pkg/scan:scan`
- Completed (2026-02-20): Wave 3 core slice (`pkg/`)
  - `pkg/` -> `go/pkg/`
- Follow-up adjustments:
  - Updated Go import paths from `github.com/carverauto/serviceradar/pkg/...` to `github.com/carverauto/serviceradar/go/pkg/...`
  - Updated Bazel labels from `//pkg/...` to `//go/pkg/...`
  - Updated path-based build/script references (`Makefile`, packaging scripts, and selected docs)
- Validation performed:
  - `go test ./go/pkg/scan -run TestDoesNotExist`
  - `go test ./go/pkg/agent -run TestDoesNotExist`
  - `bazel build //go/pkg/scan:scan //go/pkg/agent:agent //alias:scan //alias:agent`
- Completed (2026-02-20): Wave 3 Go command slice (partial `cmd/`)
  - Moved Go-owned command trees:
    - `cmd/agent/` -> `go/cmd/agent/`
    - `cmd/cli/` -> `go/cmd/cli/`
    - `cmd/data-services/` -> `go/cmd/data-services/`
    - `cmd/faker/` -> `go/cmd/faker/`
    - `cmd/tools/` -> `go/cmd/tools/`
    - `cmd/consumers/db-event-writer/` -> `go/cmd/consumers/db-event-writer/`
- Follow-up adjustments:
  - Updated Bazel labels and packaging/docker references for the moved Go cmd targets.
  - Updated moved BUILD importpaths to `github.com/carverauto/serviceradar/go/cmd/...`.
- Validation performed:
  - `bazel query "set(//go/cmd/agent:agent //go/cmd/cli:cli //go/cmd/data-services:data_services //go/cmd/faker:faker //go/cmd/tools/waitforport:wait-for-port //go/cmd/consumers/db-event-writer:db-event-writer)"`
  - `bazel build //go/cmd/agent:agent //go/cmd/cli:cli //go/cmd/data-services:data_services //go/cmd/faker:faker //go/cmd/tools/waitforport:wait-for-port //go/cmd/consumers/db-event-writer:db-event-writer`
- Completed (2026-02-20): Wave 3 Rust command slice (`cmd/` -> `rust/`)
  - `cmd/flowgger/` -> `rust/flowgger/`
  - `cmd/trapd/` -> `rust/trapd/`
  - `cmd/otel/` -> `rust/otel/`
  - `cmd/consumers/zen/` -> `rust/consumers/zen/`
  - `cmd/checkers/rperf-client/` -> `rust/checkers/rperf-client/`
  - `cmd/checkers/rperf-server/` -> `rust/checkers/rperf-server/`
  - `cmd/ebpf/profiler/` -> `rust/ebpf/profiler/`
- Follow-up adjustments:
  - Updated workspace members in `Cargo.toml` for moved Rust crates.
  - Updated `MODULE.bazel` Cargo manifest/lock references for profiler crate universe.
  - Rewrote Rust command labels/paths in docker and packaging files (including `docker/images/BUILD.bazel`, rust Dockerfiles, and `build/packaging/packages.bzl`).
- Validation status:
  - Static reference scan shows no remaining targeted Rust `cmd/*` path references in moved-source build files.
  - Follow-up path cleanup completed for residual Go packaging/build scripts (`scripts/agent/package-macos.sh`, `docker/compose/Dockerfile.agent`, and packaging shell scripts for agent/cli/datasvc/event-writer) to remove stale `cmd/...` references.
  - Full Bazel Rust target validation remains blocked by repeated crate-universe splicing stalls in this environment; `cargo check` attempts were also blocked by host-level uninterruptible Cargo cache lock states (`Ds`). Re-run the Rust Bazel build set in a clean host session as a post-move validation gate.
- Completed (2026-02-20): Wave 4 Elixir web app consolidation
  - `web-ng/` -> `elixir/web-ng/`
- Follow-up adjustments:
  - Updated Bazel labels for release packaging:
    - `//web-ng:release_tar` -> `//elixir/web-ng:release_tar` in `docker/images/BUILD.bazel` and `build/packaging/packages.bzl`.
  - Updated developer/build paths:
    - `cd web-ng` -> `cd elixir/web-ng` in `Makefile`, `AGENTS.md`, and `openspec/AGENTS.md`.
  - Updated Docker compose web-ng Dockerfile source copy roots:
    - `COPY web-ng/...` -> `COPY elixir/web-ng/...` in `docker/compose/Dockerfile.web-ng`.
  - Updated OpenSpec build spec target example:
    - `//web-ng:release_tar` -> `//elixir/web-ng:release_tar` in `openspec/specs/web-ng-build/spec.md`.
- Validation status:
  - Static reference scan confirms no remaining active `//web-ng:release_tar` labels in build/packaging files.
  - Static path scan confirms active workflow commands now use `cd elixir/web-ng`.
  - Full Bazel/Mix validation remains blocked in this host session by repeated Bazel server/connect instability and long-running toolchain cache lock behavior; rerun `bazel query //elixir/web-ng:release_tar` and `cd elixir/web-ng && mix precommit` in a clean session.
- Completed (2026-02-20): Legacy root cleanup after move waves
  - Removed now-empty legacy `cmd/` root and empty intermediate subdirectories (`cmd/checkers`, `cmd/consumers`, `cmd/ebpf`).
  - Verified prior moved roots remain absent at repository root: `age/`, `timescaledb/`, `snmp/`, `plugins/`, `web-ng/`.
- Follow-up adjustments:
  - Updated active contributor/project docs to current canonical paths:
    - `AGENTS.md`: `cmd/` -> `go/cmd/`, `pkg/` -> `go/pkg/` in repository layout summary.
    - `openspec/project.md`: Go service examples updated to `go/cmd/...`.
- Open (as of 2026-02-20): Rust-only-root objective (`2.3`)
  - Rust sources still exist outside `rust/`, including:
    - `elixir/web-ng/native/*`
    - `elixir/serviceradar_srql/native/*`
    - `arancini/*`
    - helper/build Rust sources in `docker/compose/*`
  - This requires a separate design decision on whether NIF-native Rust should be centralized under `rust/` or explicitly exempted as co-located app-native code.
- Completed (2026-02-20): Wave 5 packaging move (partial build-assets wave)
  - `packaging/` -> `build/packaging/`
- Follow-up adjustments:
  - Updated Bazel labels from `//packaging/...` to `//build/packaging/...` in package BUILD files and release wiring.
  - Updated filesystem path references from `packaging/...` to `build/packaging/...` across Dockerfiles, scripts, docs, and OpenSpec artifacts.
  - Updated RPM Dockerfiles that stage packaging sources to copy `build/packaging` into `/root/rpmbuild/SOURCES/build/packaging`.
- Validation status:
  - Static scan confirms root `packaging/` no longer exists and `build/packaging/` exists.
  - Static scan confirms no active `//packaging` Bazel labels remain in non-archived sources.
  - Full Bazel package/release target validation is pending and should be run in a clean host session (`bazel query //build/packaging/...` and `bazel query //build/release:package_artifacts`).
- Completed (2026-02-20): Wave 5 release move (partial build-assets wave)
  - `release/` -> `build/release/`
- Follow-up adjustments:
  - Updated Bazel labels from `//release:...` to `//build/release:...` in docs/specs and related build references.
  - Updated manifest path references to `build/release/package_manifest.txt` in publisher docs and release helper context.
- Validation status:
  - Static scan confirms root `release/` no longer exists and `build/release/` exists.
  - Static scan confirms no active `//release:` labels remain in non-archived sources.
  - Full Bazel target validation is pending in a clean host session (`bazel query //build/release:package_artifacts`).
- Pending (Wave 5 remainder):
  - Evaluate `alias/` relocation/retirement strategy.
  - Keep `third_party/` at root unless compatibility-safe relocation is proven.
- Assessed (2026-02-20): `alias/` relocation risk
  - Current coupling remains high (`//alias:*` referenced in active non-archived source/build files across Go command BUILD targets and docs).
  - Decision for this wave: keep `alias/` at root for compatibility; treat migration/retirement as a separate follow-up change with explicit Bazel transition plan.
