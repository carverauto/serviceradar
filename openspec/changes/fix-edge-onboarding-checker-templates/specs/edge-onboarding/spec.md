## ADDED Requirements

### Requirement: Checker Template Discovery
The system SHALL provide an API endpoint to list available checker templates for edge onboarding.

#### Scenario: List available checker templates
- **WHEN** a user requests `GET /api/admin/checker-templates`
- **THEN** the API returns a list of available checker kinds with their template keys
- **AND** each entry includes the checker kind name extracted from the template key

#### Scenario: No templates available
- **WHEN** a user requests `GET /api/admin/checker-templates`
- **AND** no templates exist in KV at `templates/checkers/` prefix
- **THEN** the API returns an empty list

### Requirement: Default Checker Templates Seeding
The system SHALL seed default checker templates into KV during deployment initialization.

#### Scenario: Templates seeded on fresh deployment
- **WHEN** the system is deployed for the first time
- **THEN** default templates for all supported checkers are available at `templates/checkers/{kind}.json`
- **AND** templates include variable placeholders for deployment-specific values

#### Scenario: Template used during edge onboarding
- **WHEN** a user creates a checker edge package without providing `checker_config_json`
- **AND** a template exists at `templates/checkers/{checker_kind}.json`
- **THEN** the template is used with variable substitution applied
- **AND** the edge package is created successfully

### Requirement: Checker Kind Selection UI
The web UI SHALL display available checker templates as selectable options during edge package creation.

#### Scenario: Dropdown populated from API
- **WHEN** user selects "checker" as the component type
- **THEN** the checker kind field displays a dropdown of available templates
- **AND** the dropdown is populated from the checker templates API

#### Scenario: Custom checker kind option
- **WHEN** user needs to use a checker kind not in the template list
- **THEN** user can select an "Other" option to enter a custom checker kind
- **AND** user must provide `checker_config_json` for custom kinds
