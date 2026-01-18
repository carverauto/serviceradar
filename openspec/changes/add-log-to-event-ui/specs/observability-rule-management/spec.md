## ADDED Requirements

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
