## ADDED Requirements

### Requirement: Package-driven credential and assignment configuration
The plugin configuration experience SHALL build integration provider options, labels, auth methods, bounded secret fields, purposes, eligible scopes, target-policy consumers, and schedule binding from approved package descriptors without provider-specific UI or native-profile branches.

#### Scenario: Administrator configures a package integration
- **GIVEN** an approved package declares one credential profile
- **WHEN** an administrator selects its provider
- **THEN** the UI SHALL collect or reference a compatible encrypted credential and eligible target scope
- **AND** the saved rule SHALL identify the package integration without plaintext secret material

#### Scenario: New package defines its credential shape
- **GIVEN** an approved package declares a valid auth method and bounded secret fields
- **WHEN** an administrator creates its credential
- **THEN** the generic credential form SHALL render the package labels and required controls
- **AND** no provider name or field SHALL be added to core/web-ng source

#### Scenario: First-party Wasm package owns its complete profile
- **GIVEN** a first-party Wasm package declares a credential profile and one or more runtime consumers
- **WHEN** the package is approved
- **THEN** the same manifest SHALL drive credential creation, rule defaults, grant materialization, plugin selection, and documentation
- **AND** core SHALL NOT register a provider module or dedicated reconciliation worker for it

#### Scenario: Package is revoked
- **GIVEN** an existing credential rule was provisioned from a package descriptor
- **WHEN** the package is revoked and reconciliation runs
- **THEN** its policy assignment and producer schedules SHALL be disabled
- **AND** the stale rule SHALL not remain runnable

### Requirement: Schema-driven package configuration
The UI SHALL render external integration settings from the package `config.schema.json`, normalize supported nested values, and validate the same schema before persistence. Provider-specific forms or validators SHALL NOT be added to core.

#### Scenario: Package defaults are displayed
- **GIVEN** an approved package schema declares bounded defaults
- **WHEN** an administrator creates its credential rule
- **THEN** the generic form SHALL display those defaults and schema labels
- **AND** persisted values SHALL retain their declared JSON types

#### Scenario: Invalid package field is submitted
- **WHEN** configuration contains an unknown key, invalid nested value, unsafe endpoint, or value outside schema bounds
- **THEN** save SHALL fail with a safe configuration error
- **AND** the invalid config SHALL not be delivered to the agent

### Requirement: Generic schedule and source controls
The settings and device views SHALL expose package-declared schedules, safe run status, Run Now, source labels, and declared observation metadata fields through generic components.

#### Scenario: Package metadata is displayed
- **GIVEN** an approved package declares an inventory source label and bounded metadata fields
- **WHEN** an operator views a matching source observation
- **THEN** the UI SHALL use the package label and field labels
- **AND** it SHALL not require those identifiers in a static core catalog

#### Scenario: Viewer attempts Run Now
- **WHEN** a user without producer execution permission attempts to run an external integration
- **THEN** ServiceRadar SHALL deny the action
- **AND** no command or credential grant SHALL be created
