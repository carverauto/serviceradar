## MODIFIED Requirements
### Requirement: God-View Performance SLOs
The system SHALL enforce measurable performance budgets for God-View interactions and snapshot delivery on supported environments. Snapshot generation budgets SHALL be observable through telemetry and configuration, but the system SHALL NOT reject an otherwise valid topology snapshot solely because its build duration exceeded the configured real-time budget.

#### Scenario: Transition budget for blast-radius mode
- **GIVEN** an already loaded snapshot revision
- **WHEN** the operator toggles blast-radius mode
- **THEN** the visual transition completes within 16 ms on supported environments

#### Scenario: Initial snapshot load budget
- **GIVEN** an authenticated operator opens God-View
- **WHEN** the first usable snapshot is requested
- **THEN** the UI renders the first usable topology frame within 3 seconds on supported environments

#### Scenario: Valid over-budget snapshot remains usable
- **GIVEN** the backend builds a valid God-View snapshot payload
- **AND** the build duration exceeds the configured real-time snapshot budget
- **WHEN** the HTTP bootstrap or topology channel requests the latest snapshot
- **THEN** the response includes the valid snapshot payload
- **AND** telemetry records the over-budget condition for operators
- **AND** the UI does not show a fatal snapshot-unavailable state solely because the budget was exceeded
