# elixir-quality-gates Specification

## Purpose
TBD - created by archiving change add-elixir-quality-gates. Update Purpose after archive.
## Requirements
### Requirement: Elixir Workspace Projects Have a Standard Analyzer Contract

The repository SHALL define a standard analyzer contract for every first-party Mix project under `elixir/`.

The contract SHALL require:

- formatting verification through the repository-owned formatter plugin stack
- compile-time warning checks
- `mix credo --strict`
- dependency auditing
- compiler-enforced architectural boundary checks where the repository declares Boundary root namespaces
- the app-specific analyzers required by this capability

The contract SHALL be exposed through documented local commands or Mix aliases so developers can run the same checks before opening a pull request.

#### Scenario: Developer runs the documented analyzer contract locally

- **GIVEN** a developer is preparing changes in a first-party Mix project under `elixir/`
- **WHEN** they run the documented analyzer contract for that app
- **THEN** the command sequence checks formatting through the repo-owned formatter plugin stack, compile-time warnings including compiler-enforced Boundary checks where configured, xref output, strict Credo with approved extra checks including duplication analysis, dependency audit, and any required app-specific analyzers for that app

### Requirement: Boundary Modeling Is Repository Owned

When the workspace adopts `Boundary`, the repository SHALL define the boundary compiler wiring and boundary declarations in version-controlled Mix and Elixir source files rather than ad hoc local configuration.

#### Scenario: Boundary rollout starts from root namespaces

- **WHEN** maintainers add `Boundary` to a first-party Mix project under `elixir/`
- **THEN** the project declares the `:boundary` compiler in repository-owned Mix config for analyzer environments
- **AND** the project defines a broad root namespace boundary in version-controlled Elixir source
- **AND** the initial rollout may export the root namespace broadly to keep the baseline green before introducing narrower sub-boundaries

### Requirement: Pull Requests Enforce Formatting And Credo

GitHub Actions SHALL run `mix format --check-formatted` and `mix credo --strict` for first-party Mix projects under `elixir/` on pull requests and pushes that touch the project, its workflow definition, or shared Elixir tooling that affects analyzer outcomes.

The repository SHALL represent each first-party Mix project through an explicit entry in a matrix-style Elixir quality workflow or an equivalent reusable workflow definition.

Compile-time warning checks, xref, dependency auditing, Dialyzer, Sobelow, and the committed OpenAPI dump check SHALL NOT be required pull-request gates. Those steps SHALL run on a scheduled BuildBuddy workflow against the default branch at least once per 24 hours.

#### Scenario: Pull request changes web-ng Elixir code

- **WHEN** a pull request changes files under `elixir/web-ng/`
- **THEN** GitHub Actions runs `mix format --check-formatted` and `mix credo --strict` for `elixir/web-ng`
- **AND** the pull request fails if formatting or Credo fails
- **AND** the pull request does not wait on compile-time warning checks, xref, dependency auditing, Dialyzer, or Sobelow
- **AND** other Mix-project quality jobs still report the required check name but do not run `mix deps.compile`

#### Scenario: Untouched Mix projects do not Mix-compile on a pull request

- **WHEN** a pull request changes files under `elixir/web-ng/` and does not change another Mix project or shared analyzer inputs
- **THEN** GitHub Actions does not run `mix deps.get` or `mix deps.compile` for `elixir/datasvc`, `elixir/palisade`, `elixir/serviceradar_agent_gateway`, `elixir/serviceradar_core`, `elixir/serviceradar_core_elx`, or `elixir/serviceradar_srql`

#### Scenario: Pull request changes core Elixir code

- **WHEN** a pull request changes files under `elixir/serviceradar_core/`
- **THEN** GitHub Actions runs `mix format --check-formatted` and `mix credo --strict` for `elixir/serviceradar_core`
- **AND** the pull request fails if formatting or Credo fails

#### Scenario: Pull request changes another Elixir project

- **WHEN** a pull request changes files under another first-party Mix project in `elixir/`
- **THEN** GitHub Actions runs `mix format --check-formatted` and `mix credo --strict` for that project or for the CI job grouping that covers it
- **AND** the pull request fails if formatting or Credo fails

#### Scenario: CI enumerates the Elixir workspace explicitly

- **WHEN** maintainers review the repository-owned Elixir quality workflow definition
- **THEN** they can identify how each first-party Mix project under `elixir/` is mapped into CI

#### Scenario: Daily BuildBuddy run covers the rest of the analyzer contract

- **WHEN** the scheduled BuildBuddy Elixir quality action runs against the default branch
- **THEN** it runs compile-time warning checks, xref, strict Credo, dependency auditing, and Phoenix Sobelow for managed apps
- **AND** a failure of that scheduled action does not block an unrelated pull request from merging

### Requirement: Elixir Workspace Projects Run Type Analysis Unless Explicitly Waived

First-party Mix projects under `elixir/` SHALL run Dialyzer as part of the analyzer contract, with cached PLTs or equivalent reuse to keep CI execution practical, unless a repository-owned temporary waiver is recorded for that project.

#### Scenario: Type analysis runs for a managed app

- **WHEN** a developer runs the documented analyzer contract locally without a Dialyzer waiver
- **THEN** Dialyzer executes for that application
- **AND** cached PLT state is reused when available

#### Scenario: Automated CI may waive Dialyzer

- **WHEN** GitHub Actions or the scheduled BuildBuddy Elixir quality action runs the analyzer contract
- **THEN** Dialyzer MAY be skipped
- **AND** the waiver is encoded as `--skip-dialyzer` on the documented quality script rather than by omitting Dialyzer from the local contract

#### Scenario: Temporary Dialyzer waiver is tracked explicitly

- **GIVEN** a legacy fork in `elixir/` cannot yet complete Dialyzer successfully under the repository toolchain
- **WHEN** maintainers apply a temporary waiver
- **THEN** the waiver is encoded in repository-owned workflow metadata for that specific project
- **AND** the rest of the analyzer contract still runs for that project

### Requirement: Phoenix Applications Run Security Analysis

First-party Mix projects under `elixir/` that expose Phoenix endpoints SHALL run Sobelow as part of the analyzer contract using repository-owned configuration.

#### Scenario: Phoenix security analysis runs for web-ng

- **GIVEN** `elixir/web-ng` is a managed Phoenix application
- **WHEN** the scheduled BuildBuddy Elixir quality action runs
- **THEN** Sobelow executes with repository-owned configuration
- **AND** a Sobelow finding fails that scheduled action
- **AND** Sobelow is not a required pull-request gate

### Requirement: Workspace Analyzer Exclusions And Waivers Are Explicit And Version Controlled

The repository SHALL keep analyzer suppressions, exclusions, and approved temporary waivers in the `elixir/` workspace in version-controlled configuration rather than ad hoc CI logic.

#### Scenario: Generated code is excluded from analyzer noise

- **GIVEN** the repository contains generated or vendored Elixir code that is not intended to satisfy the managed analyzer baseline
- **WHEN** analyzer configuration excludes that code
- **THEN** the exclusions are stored in version-controlled config files
- **AND** the exclusion scope is limited to the generated, vendored, or explicitly waived paths
