## MODIFIED Requirements
### Requirement: Unified Rule Builder UI
The system SHALL provide a unified UI for managing log normalization rules (Zen) and response rules (stateful alert engine) without requiring users to edit raw JSON. The system SHALL allow operators to create a response rule from a log entry with prefilled fields.

#### Scenario: Create a log normalization rule
- **WHEN** an operator creates a log normalization rule in the UI
- **THEN** the rule SHALL be saved for the tenant
- **AND** the UI SHALL show the enabled rule in the list

#### Scenario: Create a response rule
- **WHEN** an operator creates a response rule in the UI
- **THEN** the rule SHALL be saved for the tenant
- **AND** the UI SHALL show the enabled rule in the list

#### Scenario: Create a response rule from a log entry
- **WHEN** an operator opens the rule builder from a log entry
- **THEN** the rule builder SHALL render with log-derived fields prefilled
- **AND** saving the rule SHALL succeed without runtime errors
