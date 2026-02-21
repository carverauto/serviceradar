## Context
Repository structure drift has accumulated over time and now spans multiple languages and build systems. Issue #2851 requests a broad cleanup, but this cannot be treated as a single bulk move without sequencing because Bazel labels, Go imports, Mix project paths, and release tooling have different coupling points.

## Current Snapshot (Issue #2851 Scope)
Relevant top-level directories currently include: `cmd/`, `pkg/`, `internal/`, `web-ng/`, `elixir/`, `rust/`, `scripts/`, `snmp/`, `plugins/`, `age/`, `timescaledb/`, `release/`, `packaging/`, `alias/`, `third_party/`, and `build/`.

Target mapping for requested cleanup:
- `cmd/`, `pkg/`, `internal/` -> `go/`
- `web-ng/` -> `elixir/` (single canonical home)
- `age/`, `timescaledb/` -> `database/`
- `snmp/`, `plugins/` -> `contrib/`
- `packaging/`, selected `release/`, `alias/` -> `build/`
- `third_party/` -> conditional move (retain at root if Bazel compatibility requires)

## Goals / Non-Goals
- Goals:
  - Establish a stable, language-first repository layout with clear ownership boundaries.
  - Preserve build/test/release behavior during migration via phased updates.
  - Eliminate duplicate or ambiguous `web-ng` placement and simplify Elixir app discovery.
  - Reduce long-term maintenance burden by removing unused scripts and stale path aliases.
- Non-Goals:
  - No product feature changes.
  - No protocol/API semantic changes.
  - No redesign of runtime architecture beyond repository organization.

## Decisions
- Decision: Use phased migrations instead of one-shot renames.
  - Rationale: Limits break radius and allows validation between move groups.
- Decision: Canonical top-level directories are `go/`, `elixir/`, `rust/`, `database/`, `build/`, and `contrib/`.
  - Rationale: Aligns layout to language/runtime ownership and support responsibilities.
- Decision: Keep temporary compatibility hooks only where required, then remove them in the same change stream.
  - Rationale: Avoids permanent dual-path complexity.

## Risks / Trade-offs
- Risk: High volume rename churn can break Bazel labels and imports in non-obvious places.
  - Mitigation: Perform deterministic move batches and run targeted validation after each batch.
- Risk: `third_party` relocation may conflict with Bazel conventions and external dependency resolution.
  - Mitigation: Treat `third_party` as conditional; move only after proof that tooling compatibility is preserved.
- Risk: Script cleanup may remove rarely used operational workflows.
  - Mitigation: Require usage audit before deletion and document replacements.

## Migration Plan
1. Inventory and classify all move candidates, including explicit exclusions for generated/system directories.
2. Wave 1 (low risk): move strictly isolated assets first (for example database and contrib candidates with minimal code import coupling).
3. Wave 2 (medium risk): consolidate Go sources into `go/` and patch module/import/build references.
4. Wave 3 (high risk): consolidate `web-ng` under `elixir/` and remove alternate roots only after Mix/Bazel/docs parity checks pass.
5. Wave 4 (conditional): relocate build/support assets (`packaging`, `release`, `alias`, `third_party`) only where tooling compatibility is verified.
6. Remove obsolete paths/shims and finalize contributor documentation with canonical root layout ownership.

## Open Questions
- Should `third_party` remain at repo root for Bazel compatibility, even if other build assets move under `build/`?
- Which `scripts/` entries are actively used by CI/CD versus local-only workflows?
