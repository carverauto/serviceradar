## ADDED Requirements

### Requirement: Unified Rule Builder UI
The system SHALL provide a unified UI for managing log normalization rules (Zen) and response rules (stateful alert engine) without requiring users to edit raw JSON.

#### Scenario: Create a log normalization rule
- **WHEN** an operator creates a log normalization rule in the UI
- **THEN** the rule SHALL be saved for the tenant
- **AND** the UI SHALL show the enabled rule in the list

#### Scenario: Create a response rule
- **WHEN** an operator creates a response rule in the UI
- **THEN** the rule SHALL be saved for the tenant
- **AND** the UI SHALL show the enabled rule in the list

### Requirement: Settings Navigation Consolidation
The system SHALL provide a shared Settings layout with a navigation entry for the unified rule builder UI.

#### Scenario: Navigate to the rule builder from Settings
- **WHEN** an operator opens the Settings section
- **THEN** the navigation SHALL include an entry for rule management
- **AND** selecting it SHALL render the unified rule builder UI

### Requirement: Zen Rule Persistence and KV Sync
The system SHALL persist Zen rule definitions in the tenant schema and SHALL publish compiled JDM payloads to the datasvc KV store on create, update, and delete.

#### Scenario: Publish a new Zen rule
- **WHEN** a Zen rule is created
- **THEN** the compiled JDM SHALL be written to the KV path for the tenant
- **AND** the rule record SHALL store the KV revision metadata

#### Scenario: Disable a Zen rule
- **WHEN** a Zen rule is disabled
- **THEN** the KV entry SHALL be removed or marked inactive
- **AND** the rule record SHALL reflect the disabled state

### Requirement: Default Zen Rules and Reconciliation
The system SHALL seed baseline Zen rules into each tenant schema during onboarding (including the platform tenant)
and SHALL reconcile stored Zen rules to datasvc KV from core-elx.

#### Scenario: Tenant onboarding seeds Zen rules
- **WHEN** a tenant is created
- **THEN** the default Zen rules SHALL be inserted into the tenant schema
- **AND** each rule SHALL be eligible for KV sync without manual tooling

#### Scenario: Core-elx reconciles Zen rules
- **WHEN** core-elx starts or performs a scheduled reconciliation
- **THEN** active Zen rules in the database SHALL be re-published to KV

### Requirement: Default Passthrough Rules
The system SHALL seed a default passthrough rule and template for every supported Zen subject and SHALL label them
as the baseline option.

#### Scenario: Passthrough defaults are seeded
- **WHEN** a tenant is onboarded
- **THEN** each supported Zen subject SHALL have a passthrough rule
- **AND** each supported Zen subject SHALL have a passthrough template

#### Scenario: Passthrough defaults are labeled
- **WHEN** an operator reviews Zen rules or templates
- **THEN** passthrough defaults SHALL be labeled as the baseline option via name or description

### Requirement: Tenant-Scoped Rule Enforcement
The system SHALL enforce tenant isolation for all rule CRUD operations using Ash multi-tenancy.

#### Scenario: Cross-tenant access is denied
- **GIVEN** a user from tenant A
- **WHEN** the user attempts to read or modify tenant B rules
- **THEN** the request SHALL be denied

### Requirement: Rule Templates and Validation
The system SHALL validate rule inputs against supported subjects and templates, and SHALL provide validation errors in the UI.

#### Scenario: Unsupported subject is rejected
- **WHEN** a user selects an unsupported subject
- **THEN** the system SHALL reject the rule with a validation error

### Requirement: Tenant-Scoped Template Libraries
The system SHALL provide tenant-scoped template libraries for Zen rules and response rules, seeded with editable default templates.

#### Scenario: Default templates are available
- **WHEN** an operator opens the template library
- **THEN** the system SHALL show seeded default templates for the tenant

#### Scenario: Create a custom template
- **WHEN** an operator creates a new template
- **THEN** the template SHALL be saved for the tenant

#### Scenario: Edit a template
- **WHEN** an operator edits an existing template
- **THEN** the template definition SHALL be updated
- **AND** existing rules SHALL remain unchanged unless explicitly edited

### Requirement: Template-Based Rule Creation
The system SHALL allow operators to select a template when creating or editing Zen and response rules, using the template to prefill builder fields.

#### Scenario: Create a rule from a template
- **WHEN** an operator selects a template while creating a rule
- **THEN** the rule builder SHALL prefill fields from the template
