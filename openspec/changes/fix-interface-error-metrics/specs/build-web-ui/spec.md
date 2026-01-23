## ADDED Requirements
### Requirement: Interface metrics charts render error counters
The web UI SHALL render interface error counter charts when `in_errors` and `out_errors` are present in SRQL interface metrics responses.

#### Scenario: Error counters displayed
- **GIVEN** the interface metrics SRQL response includes `in_errors` and `out_errors`
- **WHEN** a user views the interface metrics section
- **THEN** the UI shows charts for inbound and outbound errors

#### Scenario: Empty-state for missing error counters
- **GIVEN** the interface metrics SRQL response includes `in_errors: null` and `out_errors: null`
- **WHEN** a user views the interface metrics section
- **THEN** the UI shows an empty-state message indicating error counters are not yet available
