## ADDED Requirements

### Requirement: Component Template Discovery
The system SHALL provide an API endpoint to list available component templates for edge onboarding.

#### Scenario: List available component templates
- **WHEN** a user requests `GET /api/admin/component-templates?component_type=checker&security_mode={mode}`
- **THEN** the API returns a list of available templates for that component type with their template keys
- **AND** each entry includes the component type, checker kind, and security mode derived from the template key

#### Scenario: No templates available
- **WHEN** a user requests `GET /api/admin/component-templates` with `security_mode=mtls`
- **AND** no templates exist in KV at `templates/checkers/mtls/` prefix
- **THEN** the API returns an empty list

### Requirement: Default Component Templates Seeding
The system SHALL seed default component templates into KV during deployment initialization.

#### Scenario: Templates seeded on fresh deployment
- **WHEN** the system is deployed for the first time
- **THEN** default templates for supported checkers are available at `templates/checkers/{security_mode}/{kind}.json`
- **AND** templates include variable placeholders for deployment-specific values

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
- **THEN** user can select an "Other" option to enter a custom checker kind
- **AND** user must provide `checker_config_json` for custom kinds
