## Context

The repo contains nine first-party Mix projects under `elixir/`: `connection`, `datasvc`, `elixir_uuid`, `protobuf`, `serviceradar_agent_gateway`, `serviceradar_core`, `serviceradar_core_elx`, `serviceradar_srql`, and `web-ng`. Analyzer support is uneven across that workspace. Some projects already ship `.formatter.exs`, `.credo.exs`, or `dialyxir`, but current CI only runs Credo in dedicated workflows for a subset of the workspace, and there is no spec defining which analyzers must pass before Elixir changes merge.

Issue #3029 lists a broad tool wishlist. Some items are immediate quality gates (`dialyzer`, `credo`, `sobelow`, dependency audits, `mix xref`), while others are opinionated formatter or architecture tools (`Styler`, `Boundary`, `rustywind`, `ex_dna`, `ex_slop`) that can add noise or reshape the codebase. The proposal should establish a stable baseline first, then evaluate optional tools separately.

## Goals / Non-Goals

- Goals:
  - Define a repo-standard analyzer baseline for every first-party Mix project under `elixir/`
  - Keep local and CI analyzer commands aligned
  - Catch style, compiler, type, dependency, and Phoenix security regressions before merge
  - Preserve high-signal analyzer output with explicit exclusions for generated and vendored code
- Non-Goals:
  - Mandate optional formatter or architecture tools from the issue checklist
  - Eliminate every pre-existing analyzer finding without scoped suppressions or phased cleanup

## Decisions

- Decision: The managed-app scope is every first-party Mix project under `elixir/`.
  - Why: The issue asks for Elixir analyzer coverage, and partial workspace coverage would preserve the current inconsistency.
  - Alternative considered: Restrict the change to `web-ng` and `serviceradar_core`.
  - Rationale for rejection: That leaves the rest of the Elixir workspace outside the quality gate and does not meet the stated intent.

- Decision: The required analyzer suite is formatting verification, `mix compile --warnings-as-errors`, `mix credo --strict`, dependency auditing, `mix dialyzer`, and `mix sobelow` for Phoenix apps.
  - Why: This covers the concrete gaps raised in issue #3029 while staying centered on actionable code-quality and security feedback.
  - Alternative considered: Keep CI at Credo-only and leave the rest to local convention.
  - Rationale for rejection: That does not solve the inconsistency the issue is describing.

- Decision: CI and local development must share the same analyzer contract through documented aliases or an equivalent documented command sequence.
  - Why: Separate local and CI behavior leads to churn and “passes locally” drift.

- Decision: Generated, vendored, or intentionally exempted paths inside the `elixir/` workspace must be excluded through version-controlled config rather than ad hoc CI exceptions.
  - Why: The repo already contains generated protobuf code and vendored dependencies that would otherwise dominate analyzer output.

- Decision: `Styler`, `Boundary`, `rustywind`, `ex_dna`, and `ex_slop` are deferred.
  - Why: They need a separate benefit/noise evaluation after the baseline gates are in place.

## Risks / Trade-offs

- Dialyzer can add significant CI time and may require PLT caching or staged cleanup.
- Sobelow and dependency audit tooling can produce noisy findings that require project-specific configuration.
- Strict analyzer enforcement may surface existing debt that has to be suppressed or fixed before the workflows can go green.

## Migration Plan

1. Inventory current analyzer support and exclusions across every first-party Mix project under `elixir/`.
2. Add missing dependencies, aliases, and config files required for the analyzer contract.
3. Expand the GitHub Actions workflows to run the full analyzer suite for touched Elixir apps and libraries.
4. Fix or explicitly suppress baseline findings in version-controlled config.
5. Document the local command sequence and deferred analyzer candidates.

## Open Questions

- Should `mix xref warnings` be included in the required contract immediately, or folded into the compile/warnings step if it produces overlapping signal?
- Should shared support libraries such as `connection` and `elixir_uuid` run in dedicated per-project workflows, or should CI group multiple non-Phoenix Mix projects into a single Elixir analyzer job?
