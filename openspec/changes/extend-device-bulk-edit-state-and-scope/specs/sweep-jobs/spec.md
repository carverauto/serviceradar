## MODIFIED Requirements

### Requirement: Device Bulk Edit for Tagging

The system SHALL persist bulk edits made from the device inventory view to the targeted device records so the resulting tags and states are visible to downstream consumers such as sweep group targeting. The editor's controls and its target-scope behavior SHALL be as specified by the `Bulk Tag Application` requirement in the `device-inventory` capability.

#### Scenario: Bulk select devices for tag application
- **GIVEN** a user in the device inventory view
- **WHEN** they select multiple devices using checkboxes
- **AND** choose "Bulk Edit" from bulk actions
- **THEN** the bulk editor SHALL allow tag application for the selection

#### Scenario: Apply tags to selection
- **GIVEN** the bulk editor
- **WHEN** the user adds tags (key or key/value)
- **AND** confirms the operation
- **THEN** the selected devices SHALL have those tags applied

#### Scenario: Bulk-applied tags reach sweep targeting
- **GIVEN** a user applies `tags.env = 'prod'` to devices through the device inventory bulk editor
- **WHEN** a sweep group targeting rule `tags.env = 'prod'` is compiled
- **THEN** those devices SHALL be included
