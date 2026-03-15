## Context

The repo contains eight first-party Mix projects under `elixir/`: `connection`, `datasvc`, `elixir_uuid`, `serviceradar_agent_gateway`, `serviceradar_core`, `serviceradar_core_elx`, `serviceradar_srql`, and `web-ng`. Analyzer support is uneven across that workspace. Some projects already ship `.formatter.exs`, `.credo.exs`, or `dialyxir`, but current CI only runs Credo in dedicated workflows for a subset of the workspace, and there is no spec defining which analyzers must pass before Elixir changes merge.

Issue #3029 lists a broad tool wishlist. Some items are immediate quality gates (`dialyzer`, `credo`, `sobelow`, dependency audits, `mix xref`), while others are opinionated formatter or architecture tools (`Styler`, `Boundary`, `rustywind`) that can add noise or reshape the codebase. The repo already established the baseline gates, and the remaining follow-up work is to adopt the deferred analyzers that can be added without turning the rollout into an architecture rewrite. `mix_audit`, `ex_slop`, `ex_dna`, and `Styler` fit directly. `Boundary` becomes viable once the rollout is scoped to broad root namespaces instead of deep per-domain enforcement.

## Goals / Non-Goals

- Goals:
  - Define a repo-standard analyzer baseline for every first-party Mix project under `elixir/`
  - Keep local and CI analyzer commands aligned
  - Catch style, compiler, type, dependency, and Phoenix security regressions before merge
  - Ensure every first-party Mix project has explicit CI representation instead of relying on partial coverage
  - Preserve high-signal analyzer output with explicit exclusions for generated and vendored code
- Non-Goals:
  - Mandate deferred architecture or frontend-only tools from the issue checklist
  - Eliminate every pre-existing analyzer finding without scoped suppressions or phased cleanup

## Decisions

- Decision: The managed-app scope is every first-party Mix project under `elixir/`.
  - Why: The issue asks for Elixir analyzer coverage, and partial workspace coverage would preserve the current inconsistency.
  - Alternative considered: Restrict the change to `web-ng` and `serviceradar_core`.
  - Rationale for rejection: That leaves the rest of the Elixir workspace outside the quality gate and does not meet the stated intent.

- Decision: The required analyzer suite is formatting verification through the repo-owned formatter plugin stack, compile-time warning checks, xref reporting, `mix credo --strict` with approved `ex_slop` and `ex_dna` checks, dependency auditing (`mix hex.audit` and `mix deps.audit`), `mix dialyzer`, and `mix sobelow` for Phoenix apps.
  - Why: This covers the concrete gaps raised in issue #3029 while staying centered on actionable code-quality and security feedback, while making style normalization part of the same formatter pass developers already run.
  - Alternative considered: Keep CI at Credo-only and leave the rest to local convention.
  - Rationale for rejection: That does not solve the inconsistency the issue is describing.

- Decision: CI and local development must share the same analyzer contract through documented aliases or an equivalent documented command sequence.
  - Why: Separate local and CI behavior leads to churn and “passes locally” drift.

- Decision: CI should represent the Elixir workspace through one matrix-style workflow or reusable workflow pattern that enumerates every first-party Mix project and its analyzer flags.
  - Why: This keeps project coverage explicit while avoiding a sprawl of nearly identical workflow files.
  - Alternative considered: One standalone workflow file per Mix project.
  - Rationale for rejection: It adds maintenance overhead without improving the quality signal.

- Decision: Generated, vendored, or intentionally exempted paths inside the `elixir/` workspace must be excluded through version-controlled config rather than ad hoc CI exceptions.
  - Why: The repo already contains generated code and vendored dependencies that would otherwise dominate analyzer output.

- Decision: Temporary analyzer waivers are allowed only when they are encoded per project in repository-owned workflow metadata and tied to legacy fork constraints.
  - Why: Some older forked projects cannot satisfy every analyzer under the current Beam toolchain without a larger remediation pass.
  - Alternative considered: Block the whole rollout until every legacy project is brought to zero warnings and full Dialyzer coverage.
  - Rationale for rejection: That turns the quality-gates change into a broad upstream modernization effort.

- Decision: `mix_audit`, `ex_slop`, `ex_dna`, `Styler`, and an initial `Boundary` rollout are part of the managed analyzer contract; `rustywind` remains deferred.
  - Why: `mix_audit`, `ex_slop`, and `ex_dna` fit the existing CI contract. `Styler` fits the contract once it is treated as a repo-owned formatter plugin and the workspace absorbs its baseline rewrite. `Boundary` becomes tractable when the initial rollout models each first-party Mix project through broad root namespace boundaries and compiler wiring, rather than trying to enforce fine-grained domain boundaries immediately. `rustywind` is a Tailwind class sorter rather than a shared Mix-project analyzer.

## Boundary rollout strategy

- Add the `:boundary` compiler in `:dev` and `:test` for each first-party Mix project under `elixir/`.
- Declare a broad root boundary for each project namespace so `mix compile --warnings-as-errors` can enforce architectural wiring without forcing a large rewrite.
- Export the root namespaces broadly in the initial pass to establish the compiler-enforced contract with a stable baseline.
- Leave deeper sub-boundary modeling as follow-up work after the root rollout is green.

## Risks / Trade-offs

- Dialyzer can add significant CI time and may require PLT caching or staged cleanup.
- Sobelow, dependency audit tooling, and the new Credo-extension checks can produce noisy findings that require project-specific configuration or selective check enablement.
- Strict analyzer enforcement may surface existing debt that has to be suppressed or fixed before the workflows can go green.

## Migration Plan

1. Inventory current analyzer support and exclusions across every first-party Mix project under `elixir/`.
2. Add missing dependencies, aliases, and config files required for the analyzer contract.
3. Replace or consolidate the current narrow Elixir lint workflows with a matrix-style workflow or reusable workflow pattern that runs the full analyzer suite for touched Elixir apps and libraries.
4. Fix or explicitly suppress baseline findings in version-controlled config.
5. Document the local command sequence and the remaining deferred analyzer candidates.

## Open Questions

- None at proposal time.
