## ADDED Requirements

### Requirement: Unified credential inventory
The system SHALL provide a single operator-facing credentials area for reusable encrypted secrets and scoped credential rules across ServiceRadar integrations.

#### Scenario: View all reusable credentials
- **GIVEN** an authorized admin opens the credentials settings page
- **WHEN** encrypted credential records exist for multiple providers
- **THEN** the UI SHALL list each credential with provider, auth method, redacted status, rotation metadata, and usage summary
- **AND** plaintext secret material SHALL NOT be rendered, logged, or exposed in LiveView assigns intended for templates

#### Scenario: Filter credentials by provider
- **GIVEN** credentials exist for AWX, Proxmox, SNMP, SSH, and plugin integrations
- **WHEN** the admin filters by provider
- **THEN** the UI SHALL show only matching credentials and rules
- **AND** it SHALL keep provider labels stable and human-readable

### Requirement: Descriptor-driven credential selection
The system SHALL build Wasm integration provider, authentication, secret-field, rule, and runtime-consumer choices from approved signed package descriptors. Core and web-ng SHALL NOT maintain provider-specific menus, module registries, allowlists, forms, serializers, defaults, grant builders, parameter builders, workers, or documentation links for Wasm providers.

#### Scenario: Approved descriptor becomes selectable
- **GIVEN** an approved package publishes a valid credential descriptor
- **WHEN** an admin opens the credential provider menu
- **THEN** the descriptor label and auth methods SHALL be selectable
- **AND** no provider-specific core or web-ng source change SHALL be required

#### Scenario: Wasm provider has no native fallback
- **GIVEN** a Wasm provider package is absent, unapproved, revoked, or invalid
- **WHEN** the catalog and materializer are loaded
- **THEN** that provider SHALL NOT be supplied by a compiled native profile or static registry
- **AND** stale package-owned assignments SHALL fail closed or be disabled

#### Scenario: Descriptor fields create an encrypted credential
- **GIVEN** the selected auth descriptor declares bounded required and secret fields
- **WHEN** the admin submits valid values
- **THEN** the system SHALL serialize the fields into a versioned encrypted credential payload
- **AND** it SHALL expose only fields explicitly marked as public metadata

#### Scenario: Package declares target-policy consumers
- **GIVEN** an approved package declares bounded target-policy consumers for its purposes and auth methods
- **WHEN** an enabled credential rule is reconciled
- **THEN** core SHALL validate and interpret the declared plugin ID, grant, constraints, and public parameter template
- **AND** no provider module SHALL execute inside core

#### Scenario: Undeclared provider is submitted
- **WHEN** a client submits a provider, auth method, field, or control absent from the validated catalog
- **THEN** the system SHALL reject the request
- **AND** it SHALL not persist partial secret material

### Requirement: Inline secret creation for credential rules
Credential rule creation SHALL allow admins to create or rotate the referenced encrypted secret inline while preserving the ability to select an existing secret.

#### Scenario: Create rule with new secret
- **GIVEN** an admin creates a scoped credential rule
- **WHEN** the admin enters new secret material in the rule form
- **THEN** the system SHALL create the encrypted secret and rule in one atomic operation
- **AND** the rule SHALL reference the new secret ID

#### Scenario: Create rule with existing secret
- **GIVEN** an admin has an existing encrypted credential secret
- **WHEN** the admin selects it while creating a rule
- **THEN** the rule SHALL reference the existing secret
- **AND** no new secret record SHALL be created

### Requirement: Credential consumer visibility
The system SHALL show where each credential is used without exposing secret material.

#### Scenario: Secret linked to multiple consumers
- **GIVEN** a secret is used by an AWX controller and a credential rule
- **WHEN** an admin opens the secret details
- **THEN** the UI SHALL list those consumers with links where available
- **AND** it SHALL NOT disclose the secret payload

### Requirement: Provider-neutral credential rule language
Credential rule UI copy and docs links SHALL describe rules as scoped credential bindings for ServiceRadar integrations, not as a Proxmox-only feature.

#### Scenario: Open new credential rule form
- **GIVEN** an admin opens the new credential rule form
- **WHEN** no provider has been selected yet
- **THEN** the form SHALL ask for a catalog provider before showing descriptor fields
- **AND** it SHALL NOT default to provider-specific language or target queries before a descriptor is selected
