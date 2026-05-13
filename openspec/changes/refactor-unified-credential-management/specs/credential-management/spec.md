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

### Requirement: Provider preset selection
The system SHALL use provider presets for supported credential types instead of requiring free-text provider and auth-method entry in the default workflow.

#### Scenario: Create AWX token secret
- **GIVEN** an admin selects provider `AWX / Ansible`
- **WHEN** the admin chooses API token authentication and saves a token
- **THEN** the system SHALL create an encrypted credential secret with provider `awx`
- **AND** the UI SHALL show a redacted token status and generated secret ID only as advanced metadata

#### Scenario: Create Proxmox API token secret
- **GIVEN** an admin selects provider `Proxmox VE`
- **WHEN** the admin chooses API token authentication
- **THEN** the form SHALL request user, realm, token ID, token secret, and TLS policy
- **AND** it SHALL store the token payload encrypted at rest

#### Scenario: Advanced custom provider
- **GIVEN** a provider is not yet modeled as a preset
- **WHEN** an admin enables advanced custom provider mode
- **THEN** the UI MAY allow free-text provider/auth metadata
- **AND** it SHALL mark the credential as custom and require explicit redaction/payload handling

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
- **THEN** the form SHALL ask for a provider preset before showing provider-specific fields
- **AND** it SHALL NOT default to Proxmox-specific language or target queries unless Proxmox is selected
