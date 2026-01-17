# zen-rule-editor Specification

## Purpose
TBD - created by archiving change add-zen-jdm-editor. Update Purpose after archive.
## Requirements
### Requirement: Zen rule editor exposes JDM definitions
The system SHALL provide a Zen rule editor that loads and saves the actual JDM JSON definition for each Zen rule.

#### Scenario: Edit existing rule
- **GIVEN** a tenant has an existing Zen rule
- **WHEN** an operator opens the rule editor
- **THEN** the editor SHALL load the rule’s JDM definition
- **AND** saving SHALL persist the updated JDM definition to the tenant-scoped rule

#### Scenario: Create new rule from scratch
- **WHEN** an operator creates a new Zen rule
- **THEN** the editor SHALL start with an empty JDM definition
- **AND** the new rule SHALL be persisted with the authored JDM JSON

### Requirement: Canvas and JSON views stay in sync
The editor SHALL provide both a canvas view and a raw JSON view, with round-trip synchronization.

#### Scenario: Canvas updates JSON
- **GIVEN** the canvas view is active
- **WHEN** the user edits the decision graph
- **THEN** the JSON view SHALL reflect the updated JDM definition

#### Scenario: JSON updates canvas
- **GIVEN** the JSON view is active
- **WHEN** the user edits valid JDM JSON
- **THEN** the canvas view SHALL update to match the JSON definition

### Requirement: Rule type library
The system SHALL provide a tenant-scoped library of reusable Zen rule types that can be created, edited, and cloned into rules.

#### Scenario: Clone rule type into a rule
- **GIVEN** a rule type exists in the library
- **WHEN** an operator clones it into a Zen rule
- **THEN** the new rule SHALL inherit the rule type’s JDM definition

### Requirement: Tenant scoping and RBAC
The rule editor SHALL enforce tenant scoping and role-based access control.

#### Scenario: Viewer access
- **GIVEN** a viewer role user
- **WHEN** they open the Zen rule editor
- **THEN** the UI SHALL be read-only

#### Scenario: Operator access
- **GIVEN** an operator role user
- **WHEN** they edit and save a rule
- **THEN** the changes SHALL be persisted for the current tenant only

### Requirement: KV sync for Zen rules
The system SHALL sync Zen rule JDM definitions to the datasvc KV store after create/update/delete.

#### Scenario: Rule update sync
- **WHEN** a Zen rule is updated
- **THEN** the KV entry for the rule SHALL be updated with the rule’s JDM definition

