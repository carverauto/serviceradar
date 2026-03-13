# Change: Add Elixir quality gates

## Why

Issue #3029 calls out a real gap in the Elixir toolchain: analyzer coverage is inconsistent across the repo, and the current GitHub Actions workflows only enforce Credo for a subset of the Elixir workspace. Formatting drift, compiler warnings, dependency advisories, type issues, and Phoenix-specific security findings can all land without a single documented quality bar or a local command sequence that matches CI.

## What Changes

- Define a standard analyzer contract for every first-party Mix project under `elixir/`, including `web-ng`, `serviceradar_core`, `serviceradar_core_elx`, `serviceradar_agent_gateway`, `serviceradar_srql`, `datasvc`, `connection`, and `elixir_uuid`
- Require the analyzer contract to cover formatting checks, compile-time warning checks, cross-reference reporting, strict Credo, dependency auditing, Dialyzer, and Phoenix security analysis where applicable
- Add documented local entrypoints and matching GitHub Actions jobs so developers and CI run the same analyzer sequence
- Consolidate repo-owned Elixir quality enforcement into a matrix-style GitHub Actions workflow or equivalent reusable workflow pattern that covers every first-party Mix project under `elixir/`
- Version-control exclusions and suppressions for generated or vendored code so analyzer output stays actionable
- Allow narrowly scoped temporary waivers in repository-owned workflow metadata for legacy forks that cannot yet satisfy a specific analyzer without upstream remediation
- Defer optional analyzer candidates from issue #3029 (`Styler`, `Boundary`, `rustywind`, `ex_dna`, `ex_slop`) to follow-up evaluation after the baseline gates are green and stable

## Impact

- Affected specs: `elixir-quality-gates` (new)
- Affected code:
  - `.github/workflows/web-ng-lint.yml`
  - `.github/workflows/serviceradar-core-lint.yml`
  - additional GitHub Actions coverage for the rest of `elixir/`
  - `elixir/`
  - repo docs for local lint/analyzer usage
- No breaking API or schema changes
