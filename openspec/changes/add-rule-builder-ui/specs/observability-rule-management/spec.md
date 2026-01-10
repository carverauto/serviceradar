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
