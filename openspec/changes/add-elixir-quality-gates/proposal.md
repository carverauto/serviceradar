# Change: Add Elixir quality gates

## Why

Issue #3029 calls out a real gap in the Elixir toolchain: analyzer coverage is inconsistent across the repo, and the current GitHub Actions workflows only enforce Credo for a subset of the Elixir workspace. Formatting drift, compiler warnings, dependency advisories, type issues, and Phoenix-specific security findings can all land without a single documented quality bar or a local command sequence that matches CI.

## What Changes

- Define a standard analyzer contract for every first-party Mix project under `elixir/`, including `web-ng`, `serviceradar_core`, `serviceradar_core_elx`, `serviceradar_agent_gateway`, `serviceradar_srql`, `datasvc`, `connection`, and `elixir_uuid`
- Require the analyzer contract to cover formatting checks, compile-time warning checks, cross-reference reporting, strict Credo with approved extra checks, dependency auditing (`mix hex.audit` and `mix deps.audit`), Dialyzer, and Phoenix security analysis where applicable
- Add documented local entrypoints and matching GitHub Actions jobs so developers and CI run the same analyzer sequence
- Consolidate repo-owned Elixir quality enforcement into a matrix-style GitHub Actions workflow or equivalent reusable workflow pattern that covers every first-party Mix project under `elixir/`
- Version-control exclusions and suppressions for generated or vendored code so analyzer output stays actionable
- Allow narrowly scoped temporary waivers in repository-owned workflow metadata for legacy forks that cannot yet satisfy a specific analyzer without upstream remediation
- Adopt the viable deferred issue #3029 analyzers that behave as drop-in quality gates today: `mix_audit` (`mix deps.audit`), `ex_slop`, and `ex_dna` through Credo integration
- Keep `Styler`, `Boundary`, and `rustywind` deferred because they are not drop-in CI gates for this workspace: `Styler` rewrites code and can change behavior, `Boundary` requires explicit architectural boundary modeling, and `rustywind` belongs to Tailwind/frontend formatting rather than the shared Mix analyzer contract

## Impact

- Affected specs: `elixir-quality-gates` (new)
- Affected code:
  - `.github/workflows/web-ng-lint.yml`
  - `.github/workflows/serviceradar-core-lint.yml`
  - additional GitHub Actions coverage for the rest of `elixir/`
  - `elixir/`
  - repo docs for local lint/analyzer usage
- No breaking API or schema changes
