## ADDED Requirements
### Requirement: Device Enrichment Rules Management UI
The web-ng Settings UI SHALL provide a Device Enrichment Rules management surface for operators.

#### Scenario: List effective rules
- **WHEN** an authorized operator navigates to Settings -> Inventory -> Device Enrichment Rules
- **THEN** the UI SHALL display effective rules with source (`builtin` or `filesystem`), enabled state, and priority

#### Scenario: Create and save a custom rule
- **WHEN** an authorized operator creates a new rule with match conditions and output mappings
- **THEN** the backend SHALL validate the rule schema
- **AND** on success the rule SHALL be persisted to the configured rules path

#### Scenario: Validation failure blocks save
- **WHEN** an operator attempts to save an invalid rule
- **THEN** the UI SHALL show structured validation errors
- **AND** the rule SHALL NOT be activated

### Requirement: Rule Simulation and Preview
The UI SHALL support simulation of enrichment rules against sample payload input before activation.

#### Scenario: Preview winning rule for sample payload
- **WHEN** an operator submits a sample payload containing SNMP metadata fields
- **THEN** the UI SHALL display the winning rule, resulting vendor/type outputs, and confidence/reason

#### Scenario: No-match preview
- **WHEN** a sample payload matches no enabled rule
- **THEN** the UI SHALL display fallback behavior and indicate no winning rule

### Requirement: Rule Import and Export
The UI SHALL support import and export of enrichment rules as YAML.

#### Scenario: Export current rules
- **WHEN** an operator exports rules
- **THEN** the system SHALL provide YAML representing the active effective rule set

#### Scenario: Import rule bundle
- **WHEN** an operator imports a YAML bundle
- **THEN** the system SHALL validate all rules before applying any change
- **AND** on success SHALL update the managed filesystem rules set
