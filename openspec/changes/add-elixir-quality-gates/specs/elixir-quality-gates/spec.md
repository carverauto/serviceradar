## ADDED Requirements

### Requirement: Elixir Workspace Projects Have a Standard Analyzer Contract

The repository SHALL define a standard analyzer contract for every first-party Mix project under `elixir/`.

The contract SHALL require:

- formatting verification
- compilation with warnings treated as errors
- `mix credo --strict`
- dependency auditing
- the app-specific analyzers required by this capability

The contract SHALL be exposed through documented local commands or Mix aliases so developers can run the same checks before opening a pull request.

#### Scenario: Developer runs the documented analyzer contract locally

- **GIVEN** a developer is preparing changes in a first-party Mix project under `elixir/`
- **WHEN** they run the documented analyzer contract for that app
- **THEN** the command sequence checks formatting, compiler warnings, strict Credo, dependency audit, and any required app-specific analyzers for that app

### Requirement: GitHub Actions Enforces the Analyzer Contract

GitHub Actions SHALL run the full analyzer contract for first-party Mix projects under `elixir/` on pull requests and pushes that touch the project, its workflow definition, or shared Elixir tooling that affects analyzer outcomes.

#### Scenario: Pull request changes web-ng Elixir code

- **WHEN** a pull request changes files under `elixir/web-ng/`
- **THEN** GitHub Actions runs the managed analyzer contract for `elixir/web-ng`
- **AND** the pull request fails if any required analyzer step fails

#### Scenario: Pull request changes core Elixir code

- **WHEN** a pull request changes files under `elixir/serviceradar_core/`
- **THEN** GitHub Actions runs the managed analyzer contract for `elixir/serviceradar_core`
- **AND** the pull request fails if any required analyzer step fails

#### Scenario: Pull request changes another Elixir project

- **WHEN** a pull request changes files under another first-party Mix project in `elixir/`
- **THEN** GitHub Actions runs the managed analyzer contract for that project or for the CI job grouping that covers it
- **AND** the pull request fails if any required analyzer step fails

### Requirement: Elixir Workspace Projects Run Type Analysis

First-party Mix projects under `elixir/` SHALL run Dialyzer as part of the analyzer contract, with cached PLTs or equivalent reuse to keep CI execution practical.

#### Scenario: Type analysis runs for a managed app

- **WHEN** the analyzer contract runs for a first-party Mix project under `elixir/`
- **THEN** Dialyzer executes for that application
- **AND** the workflow reuses PLT state or equivalent cached artifacts when available

### Requirement: Phoenix Applications Run Security Analysis

First-party Mix projects under `elixir/` that expose Phoenix endpoints SHALL run Sobelow as part of the analyzer contract using repository-owned configuration.

#### Scenario: Phoenix security analysis runs for web-ng

- **GIVEN** `elixir/web-ng` is a managed Phoenix application
- **WHEN** its analyzer contract runs
- **THEN** Sobelow executes with repository-owned configuration
- **AND** the analyzer output is treated as part of the required pull request gate

### Requirement: Workspace Analyzer Exclusions Are Explicit and Version Controlled

The repository SHALL keep analyzer suppressions and exclusions for generated code, vendored code, and approved temporary waivers in the `elixir/` workspace in version-controlled configuration rather than ad hoc CI logic.

#### Scenario: Generated code is excluded from analyzer noise

- **GIVEN** the repository contains generated or vendored Elixir code that is not intended to satisfy the managed analyzer baseline
- **WHEN** analyzer configuration excludes that code
- **THEN** the exclusions are stored in version-controlled config files
- **AND** the exclusion scope is limited to the generated, vendored, or explicitly waived paths
