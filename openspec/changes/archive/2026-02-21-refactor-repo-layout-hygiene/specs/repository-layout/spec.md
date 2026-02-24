## ADDED Requirements
### Requirement: Canonical Repository Layout
The repository SHALL maintain a canonical top-level layout that separates code and assets by ownership domain.

#### Scenario: Language directories are canonical
- **WHEN** contributors inspect the repository root
- **THEN** Go application code resides under `go/`
- **AND** Elixir applications reside under `elixir/`
- **AND** Rust code resides under `rust/`

#### Scenario: Support directories are canonical
- **WHEN** contributors inspect supporting assets at repository root
- **THEN** database-specific assets reside under `database/`
- **AND** build-only assets reside under `build/` where compatibility allows
- **AND** optional integrations and plugins reside under `contrib/`

### Requirement: Migration Safety During Layout Refactors
Repository layout refactors MUST preserve build/test/release operability throughout migration phases.

#### Scenario: Toolchain references are updated before old paths are removed
- **WHEN** a directory move is executed
- **THEN** Bazel, Make, and language-specific project references are updated for the new path
- **AND** validation commands pass before the legacy path is removed

#### Scenario: Deletions are gated by usage validation
- **WHEN** scripts or legacy aliases are candidates for removal
- **THEN** their usage is validated against active CI/CD and documented workflows
- **AND** replacements are documented before deletion

### Requirement: Web-NG Consolidation Under Elixir
The repository SHALL have a single canonical location for Web-NG within the Elixir application tree.

#### Scenario: Web-NG path is unambiguous
- **WHEN** developers locate the Web-NG Phoenix application
- **THEN** it is located under `elixir/`
- **AND** duplicate or legacy alternate locations are removed after migration
