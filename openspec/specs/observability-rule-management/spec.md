# observability-rule-management Specification

## Purpose
TBD - created by archiving change add-rule-builder-ui. Update Purpose after archive.
## Requirements
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

### Requirement: Log-to-Event Rule Creation from Log Details
The system SHALL provide a simple UI for creating log promotion rules directly from the log details view without navigating to the full rule management settings.

#### Scenario: Create promotion rule from log entry
- **GIVEN** a user with operator or admin role is viewing a log entry details page
- **WHEN** the user clicks "Create Event Rule"
- **THEN** the system SHALL display a rule builder modal pre-populated with values from the current log
- **AND** the user SHALL be able to select which match conditions to enable (message contains, severity, service name, attributes)
- **AND** submitting the form SHALL create a LogPromotionRule for the current tenant

#### Scenario: Viewer cannot create rules
- **GIVEN** a user with viewer role is viewing a log entry details page
- **WHEN** the page renders
- **THEN** the "Create Event Rule" button SHALL NOT be displayed
- **AND** the user SHALL still be able to view all log details

#### Scenario: Pre-populate match conditions from log
- **GIVEN** a log entry with body "Fetch error", severity "ERROR", and service name "db-writer"
- **WHEN** the user opens the rule builder
- **THEN** the form fields SHALL be pre-filled with:
  - Message contains: "Fetch error"
  - Severity: "ERROR"
  - Service name: "db-writer"
- **AND** each condition SHALL have a toggle to include/exclude it from the rule

#### Scenario: Validation requires at least one match condition
- **GIVEN** the rule builder modal is open
- **WHEN** the user disables all match conditions and attempts to save
- **THEN** the system SHALL display a validation error
- **AND** the rule SHALL NOT be created

### Requirement: Log Details Attribute Display
The system SHALL parse and display log attributes in a structured format when viewing log entry details.

#### Scenario: Parse structured attribute string
- **GIVEN** a log entry with attributes stored as `attributes={"error":"connection failed"},resource={"service.name":"myservice"}`
- **WHEN** the user views the log details
- **THEN** the system SHALL parse and display individual attribute key-value pairs
- **AND** each attribute SHALL be shown in its own row with the key and formatted value

#### Scenario: Handle unparseable attributes gracefully
- **GIVEN** a log entry with attributes in an unknown format
- **WHEN** the user views the log details
- **THEN** the system SHALL display the raw attribute value as-is
- **AND** the UI SHALL NOT show an error

### Requirement: Rule Testing and Preview
The system SHALL allow users to test promotion rule match conditions against recent logs before saving the rule.

#### Scenario: Test rule against recent logs
- **GIVEN** the user has configured match conditions in the rule builder
- **WHEN** the user clicks "Test Rule"
- **THEN** the system SHALL query logs from the last hour using the configured conditions
- **AND** the system SHALL display the count of matching logs
- **AND** the system SHALL display a sample of up to 10 matching log entries

#### Scenario: No matching logs found
- **GIVEN** the user has configured match conditions that don't match any recent logs
- **WHEN** the user clicks "Test Rule"
- **THEN** the system SHALL display a message indicating no logs would match
- **AND** the user SHALL still be able to save the rule

#### Scenario: Preview updates as conditions change
- **GIVEN** the user has tested a rule and sees matching results
- **WHEN** the user modifies a match condition
- **THEN** the system SHALL update the preview after a short delay (debounced)
- **AND** the new match count and samples SHALL reflect the updated conditions

### Requirement: Alert Creation Toggle in Rule Builder
The system SHALL allow users to specify whether matching events should automatically generate alerts.

#### Scenario: Enable auto-alert for promotion rule
- **GIVEN** the user is creating a promotion rule via the rule builder
- **WHEN** the user enables the "Auto-create alert" toggle
- **THEN** the created rule SHALL have `event.alert` set to `true`
- **AND** events created by this rule SHALL automatically generate alerts

#### Scenario: Disable auto-alert for promotion rule
- **GIVEN** the user is creating a promotion rule via the rule builder
- **WHEN** the user leaves the "Auto-create alert" toggle disabled
- **THEN** the created rule SHALL NOT have an `event.alert` configuration
- **AND** events created by this rule SHALL follow default alerting behavior based on severity

### Requirement: Rules UI Integration
The system SHALL display rules created from log details in the existing Rules management UI and allow further editing.

#### Scenario: View created rule in Settings
- **GIVEN** an operator has created a LogPromotionRule from the log details view
- **WHEN** the operator navigates to `/settings/rules?tab=events`
- **THEN** the newly created rule SHALL appear in the Event Promotion Rules table
- **AND** the rule SHALL show its name, subject prefix, priority, and enabled status

#### Scenario: Edit rule from Settings
- **GIVEN** a LogPromotionRule exists in the Events tab
- **WHEN** an admin clicks the edit action for that rule
- **THEN** the system SHALL allow editing the rule's match conditions, event configuration, and priority

### Requirement: NetFlow Zen rule bootstrap via deployment tooling
When NetFlow ingestion is enabled, deployment tooling SHALL load the NetFlow Zen rule bundle into datasvc KV using
`zen-put-rule` (or equivalent) so Zen can transform NetFlow records without manual intervention, retrying on
transient datasvc/NATS errors.

#### Scenario: Helm install with NetFlow enabled
- **GIVEN** the Helm values enable the NetFlow collector
- **WHEN** the Helm release is installed or upgraded
- **THEN** the NetFlow rule bundle SHALL be written to KV for the platform tenant
- **AND** the operation SHALL be idempotent when re-run
- **AND** transient KV failures SHALL trigger retries before reporting failure

#### Scenario: Static Kubernetes manifest install
- **GIVEN** the static Kubernetes manifests enable the NetFlow collector
- **WHEN** the manifests are applied
- **THEN** the NetFlow rule bundle SHALL be written to KV via `zen-put-rule`
- **AND** transient KV failures SHALL trigger retries before reporting failure
- **AND** failures after retries SHALL be surfaced in the deployment status

#### Scenario: Docker Compose NetFlow bootstrap
- **GIVEN** the Docker Compose stack enables the NetFlow collector
- **WHEN** the stack starts
- **THEN** the NetFlow rule bundle SHALL be written to KV via `zen-put-rule`
- **AND** transient KV failures SHALL trigger retries before reporting failure
- **AND** the stack SHALL surface failures if rule seeding fails after retries

