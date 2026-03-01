## MODIFIED Requirements
### Requirement: Rule Testing and Preview
The system SHALL allow users to test promotion rule match conditions against recent logs before saving the rule.

#### Scenario: Test rule against recent logs
- **GIVEN** the user has configured match conditions in the rule builder
- **WHEN** the user clicks "Test Rule"
- **THEN** the system SHALL query logs from the last hour using the configured conditions and an SRQL `time:last_1h` filter
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
