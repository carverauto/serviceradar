## ADDED Requirements
### Requirement: Dashboard Private Git Source Administration
The web UI SHALL allow authorized administrators to create, view, test, rotate, and revoke private Git sources for dashboard package imports.

#### Scenario: Create private dashboard source
- **GIVEN** an authorized administrator opens the dashboard package settings area
- **WHEN** they create a private Git source with a repository URL
- **THEN** the system SHALL generate a read-only SSH deploy keypair
- **AND** the UI SHALL display the public key and key label for installation in the upstream Git host
- **AND** the UI SHALL NOT display or return the private key

#### Scenario: Test private dashboard source
- **GIVEN** a private Git source has a deploy key installed in the upstream Git host
- **WHEN** the administrator tests connectivity
- **THEN** the UI SHALL show whether the repository can be fetched
- **AND** it SHALL show the resolved default branch or commit metadata when available

#### Scenario: Rotate private dashboard source key
- **GIVEN** a private Git source exists
- **WHEN** the administrator rotates its deploy key
- **THEN** the system SHALL generate a new keypair
- **AND** the UI SHALL display the new public key
- **AND** imports using that source SHALL fail until the new public key is installed upstream

### Requirement: Dashboard Package Import From Private Git Source
The dashboard package import UI SHALL support importing a dashboard package from a configured private Git source by ref and manifest path.

#### Scenario: Import dashboard package from configured source
- **GIVEN** an authorized administrator selects a configured private Git source
- **AND** enters a Git ref and manifest path
- **WHEN** they submit the import
- **THEN** the server SHALL fetch the manifest and renderer artifact using the stored source credential
- **AND** the UI SHALL show the imported dashboard package version and status
- **AND** no Git credential material SHALL be included in browser payloads

#### Scenario: Private import path validation failure
- **GIVEN** an administrator enters a manifest path containing parent traversal or an absolute path
- **WHEN** they submit the private Git import
- **THEN** the UI SHALL reject the request with a validation error
- **AND** the server SHALL NOT read files outside the checked-out repository
