## ADDED Requirements

### Requirement: Component Template Discovery
The system SHALL provide an API endpoint to list available component templates for edge onboarding across component types and security modes.

#### Scenario: List available component templates
- **WHEN** a user requests `GET /api/admin/component-templates?component_type={checker|agent|poller}&security_mode={mtls|spire}`
- **THEN** the API returns a list of available templates for that component type and security mode with their template keys
- **AND** each entry includes the component type, kind, security mode, and template key derived from the KV path

#### Scenario: No templates available
- **WHEN** a user requests `GET /api/admin/component-templates` with `security_mode=mtls`
- **AND** no templates exist in KV at `templates/{component}/mtls/` prefix
- **THEN** the API returns an empty list

### Requirement: Default Component Templates Seeding
The system SHALL seed default component templates into KV during deployment initialization using the appropriate security-mode prefix.

#### Scenario: Templates seeded on fresh deployment
- **WHEN** the system is deployed for the first time
- **THEN** default templates for supported checkers are available at `templates/checkers/{security_mode}/{kind}.json`
- **AND** templates include variable placeholders for deployment-specific values
- **AND** compose deployments use `security_mode=mtls` while Kubernetes Helm seeds SPIRE templates

#### Scenario: Template used during edge onboarding
- **WHEN** a user creates a checker edge package without providing `checker_config_json`
- **AND** a template exists at `templates/checkers/{security_mode}/{checker_kind}.json` (with fallback to `templates/checkers/{checker_kind}.json` for SPIRE)
- **THEN** the template is used with variable substitution applied
- **AND** the edge package is created successfully

### Requirement: Template Selection UI
The web UI SHALL display available component templates as selectable options during edge package creation.

#### Scenario: Dropdown populated from API
- **WHEN** user selects "checker" as the component type and chooses a security mode
- **THEN** the checker kind field displays a dropdown of available templates for that security mode
- **AND** the dropdown is populated from the component templates API

#### Scenario: Custom checker kind option
- **WHEN** user needs to use a checker kind not in the template list
- **THEN** user can select an "Other" option while templates are available to enter a custom checker kind
- **AND** user must provide `checker_config_json` for custom kinds
