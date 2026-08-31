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
The system SHALL show where each credential is used without exposing secret material. Consumer status SHALL include every configured live reference and non-expired active broker grant, and failure to resolve any supported consumer source SHALL make usage unavailable rather than reporting a partial zero.

#### Scenario: Secret linked to multiple consumers
- **GIVEN** a secret is used by an AWX controller and a credential rule
- **WHEN** an admin opens the secret details
- **THEN** the UI SHALL list those consumers with links where available
- **AND** it SHALL NOT disclose the secret payload

#### Scenario: Credential has one SNMP profile consumer
- **GIVEN** a credential is referenced by exactly one SNMP profile
- **WHEN** an admin views the credential usage summary
- **THEN** the summary SHALL include the profile name as a direct link to `/settings/snmp/:id/edit`
- **AND** the admin SHALL not need to navigate back through the settings hierarchy

#### Scenario: Credential has multiple navigable consumers
- **GIVEN** a credential is referenced by multiple credential rules or SNMP profiles
- **WHEN** an admin expands its usage summary
- **THEN** the UI SHALL list each consumer by name with its edit link
- **AND** it SHALL distinguish consumer kinds and counts

#### Scenario: Consumer lookup is incomplete
- **WHEN** any supported consumer source cannot be queried
- **THEN** the UI SHALL report usage as unavailable
- **AND** permanent deletion SHALL be unavailable

### Requirement: Credential lifecycle management
Authorized admins SHALL be able to edit safe public metadata, rotate secret material through write-only descriptor fields, and permanently delete an unused reusable credential.

#### Scenario: Edit credential details
- **GIVEN** an authorized admin opens Edit details for a reusable credential
- **WHEN** the admin changes its name or description
- **THEN** the system SHALL persist only the allowed public metadata
- **AND** provider, credential kind, authentication descriptor, and encrypted payload SHALL remain unchanged

#### Scenario: Rotate an internal encrypted credential
- **GIVEN** an internal credential has an active approved descriptor
- **WHEN** an authorized admin submits valid replacement material
- **THEN** every secret input SHALL have started blank and the prior secret SHALL never have been rendered or assigned to the template
- **AND** the system SHALL execute the explicit rotation lifecycle and persist the descriptor-approved public metadata

#### Scenario: Audit a secret-bearing action
- **WHEN** a credential is created or rotated with submitted secret material
- **THEN** PaperTrail SHALL NOT persist the action input map for that secret-bearing action
- **AND** database versions, lifecycle events, errors, logs, and rendered HTML SHALL not contain the submitted secret marker

#### Scenario: Attempt to rotate an unsupported credential
- **GIVEN** a credential is rotating, disabled, externally referenced, or lacks an active descriptor
- **WHEN** an admin opens or submits Rotate
- **THEN** the system SHALL reject rotation with a non-secret explanation
- **AND** it SHALL not mutate or expose existing secret material

#### Scenario: Permanently delete an unused credential
- **GIVEN** a credential has no configured consumer and no non-expired active broker grant
- **WHEN** an authorized admin confirms permanent deletion
- **THEN** the system SHALL delete the credential, its encrypted payload, and all ciphertext-bearing owned versions atomically
- **AND** it SHALL retain only a redacted append-only deletion audit with safe identity fields, actor, and timestamp

#### Scenario: Refuse deletion of a used credential
- **GIVEN** a credential has at least one configured consumer or non-expired active broker grant
- **WHEN** an admin requests permanent deletion
- **THEN** the system SHALL refuse the deletion
- **AND** it SHALL return named consumer summaries and edit links where available

#### Scenario: Forged management event
- **GIVEN** a user lacks `settings.credentials.manage`
- **WHEN** the user submits an edit, rotate, or delete event directly
- **THEN** the system SHALL perform a fresh authorization check and reject the event
- **AND** no credential state SHALL change

### Requirement: Race-safe credential reference enforcement
Every live persisted reference to a reusable credential SHALL participate in PostgreSQL referential enforcement, either through a direct restrictive foreign key or a transactionally maintained FK-backed binding row. Historical audit and immutable execution snapshots SHALL not be treated as live consumers.

#### Scenario: Concurrent consumer assignment races deletion
- **GIVEN** an unused credential is being deleted while another transaction assigns it to a consumer
- **WHEN** both transactions attempt to commit
- **THEN** PostgreSQL referential locking SHALL allow at most one operation to succeed
- **AND** the database SHALL never commit a consumer that references a deleted credential

#### Scenario: Persist denormalized network credential reference
- **WHEN** a supported text or JSON consumer persists a network-credential reference
- **THEN** the same transaction SHALL create or update a binding row with a restrictive foreign key to the credential
- **AND** deletion SHALL remain blocked until that consumer reference is removed

#### Scenario: Delete credential with historical records
- **GIVEN** a credential has only terminal grants, resolution audits, OCSF events, or immutable execution snapshots
- **WHEN** an authorized admin confirms deletion
- **THEN** terminal or expired owned grant records MAY be pruned and historical records MAY retain redacted context
- **AND** none of those historical records SHALL retain encrypted secret material or alone block deletion

### Requirement: Provider-neutral credential rule language
Credential rule UI copy and docs links SHALL describe rules as scoped credential bindings for ServiceRadar integrations, not as a Proxmox-only feature.

#### Scenario: Open new credential rule form
- **GIVEN** an admin opens the new credential rule form
- **WHEN** no provider has been selected yet
- **THEN** the form SHALL ask for a catalog provider before showing descriptor fields
- **AND** it SHALL NOT default to provider-specific language or target queries before a descriptor is selected
