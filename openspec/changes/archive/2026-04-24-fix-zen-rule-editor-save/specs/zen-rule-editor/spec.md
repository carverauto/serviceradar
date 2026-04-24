## MODIFIED Requirements
### Requirement: Zen rule editor exposes JDM definitions
The system SHALL provide a Zen rule editor that loads and saves the actual JDM JSON definition for each Zen rule, including edits made through the JDM canvas and metadata fields, without crashing on route parameter changes.

#### Scenario: Edit existing rule
- **GIVEN** a tenant has an existing Zen rule
- **WHEN** an operator opens the rule editor
- **THEN** the editor SHALL load the rule’s JDM definition
- **AND** saving SHALL persist the updated JDM definition to the tenant-scoped rule

#### Scenario: Edit rule via direct URL
- **GIVEN** a tenant has an existing Zen rule
- **WHEN** an operator opens the editor at `/settings/rules/zen/:id`
- **THEN** the LiveView SHALL load the rule without errors
- **AND** saving SHALL persist the updated JDM definition and rule metadata

#### Scenario: Create new rule from scratch
- **WHEN** an operator creates a new Zen rule
- **THEN** the editor SHALL start with an empty JDM definition
- **AND** the new rule SHALL be persisted with the authored JDM JSON
