## ADDED Requirements
### Requirement: God-View endpoint layer renders discovered endpoints
The God-View topology canvas SHALL render discovered endpoint nodes and their attachment links when the `endpoints` layer is enabled.

#### Scenario: Endpoint layer enabled
- **GIVEN** the topology payload contains backbone relations and endpoint attachment relations
- **WHEN** an operator enables or leaves enabled the `endpoints` layer
- **THEN** discovered client or endpoint nodes SHALL be rendered on the canvas
- **AND** their attachment links to the observed infrastructure device SHALL be visible

#### Scenario: Endpoint layer disabled
- **GIVEN** the topology payload contains both backbone relations and endpoint attachment relations
- **WHEN** an operator disables the `endpoints` layer
- **THEN** endpoint nodes and endpoint attachment links SHALL be hidden
- **AND** backbone infrastructure nodes and links SHALL remain visible

#### Scenario: Endpoint visibility regression coverage
- **GIVEN** automated topology UI tests execute against a fixture with at least one router, one switch, and one downstream endpoint
- **WHEN** the endpoint layer is toggled on and off
- **THEN** tests SHALL fail if the endpoint node does not appear when enabled
- **AND** tests SHALL fail if disabling the endpoint layer hides backbone infrastructure instead of only endpoint attachments
