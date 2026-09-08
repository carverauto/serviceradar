## 1. Planning and Safety Gates
- [x] 1.1 Inventory all top-level directories and map each to a target canonical home.
- [x] 1.2 Mark each move as low-risk (pure move), medium-risk (path + config updates), or high-risk (path + behavior coupling).
- [x] 1.3 Define move ordering to prevent circular breakage across Bazel, Go modules, Mix projects, and release tooling.
- [x] 1.4 Confirm exclusions for non-product/generated directories (for example `.git`, `.cache`, `target`, `logs`) so cleanup scope stays focused on source/layout assets.

## 2. Directory Consolidation
- [x] 2.1 Move Go code into `go/` and update package/module references (`cmd/`, `pkg/`, `internal/`).
- [x] 2.1a Move `internal/` to `go/internal/` and update direct Bazel/import references.
- [x] 2.1b Move `pkg/` to `go/pkg/` and update Bazel/import/module references.
- [x] 2.1c Move Go-owned `cmd/` subtrees to `go/cmd/` and update Bazel/import/module references.
- [x] 2.1d Move Rust-owned `cmd/` subtrees into `rust/` and update Bazel/Make/module references.
- [x] 2.2 Consolidate Elixir applications under `elixir/`, including `web-ng` rehoming and duplicate-path cleanup.
- [x] 2.3 Ensure Rust code is located under `rust/` only.
- [x] 2.4 Move database-oriented assets (AGE/Timescale artifacts) into `database/`.
- [x] 2.5 Move contrib-style assets to `contrib/` (`snmp/`, optional plugin assets).
- [x] 2.6 Move build-only assets to `build/` where appropriate (`packaging`, selected `release/`, `alias`, potentially `third_party` if compatibility is preserved).
- [x] 2.7 Remove now-empty legacy directories after each move wave is validated.

## 3. Tooling and Build Parity
- [x] 3.1 Update Bazel BUILD/MODULE references for relocated paths.
- [x] 3.2 Update `Makefile` and scripts for new canonical paths.
- [x] 3.3 Update Go module/workspace configuration and imports for relocated code.
- [x] 3.4 Update Elixir project references and release/build config for moved apps.
- [x] 3.5 Remove dead scripts and obsolete path references after replacement paths are active.

## 4. Validation and Documentation
- [x] 4.1 Run language-specific and repo-wide validation (`make test`, targeted Bazel, Mix compile/tests, cargo checks where affected).
- [x] 4.2 Add/update docs describing the new repository layout and migration notes for contributors.
- [x] 4.3 Remove compatibility shims/aliases once all references are migrated.
- [x] 4.4 Add a final root-level layout table in docs that lists each canonical directory and owning subsystem.
