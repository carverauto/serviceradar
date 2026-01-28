## ADDED Requirements
### Requirement: Interface Metrics Collection Configuration

The system SHALL persist interface metrics collection selections and treat an empty selection as metrics disabled for the interface.

#### Scenario: Persist interface metrics selection
- **GIVEN** a user enables metrics collection for an interface and selects specific metrics
- **WHEN** the selection is saved
- **THEN** the interface metrics configuration SHALL persist the selected metrics
- **AND** the interface SHALL be marked as metrics-enabled

#### Scenario: Disable metrics collection clears selection
- **GIVEN** an interface with metrics collection enabled and saved selections
- **WHEN** the user disables metrics collection or removes the final selected metric
- **THEN** the interface metrics selection SHALL be cleared
- **AND** the interface SHALL be marked as metrics-disabled

#### Scenario: Remove composite groups on disable
- **GIVEN** an interface with a composite group bound to its metrics collection
- **WHEN** metrics collection is disabled for that interface
- **THEN** the composite group SHALL be deleted
- **AND** the interface configuration returned to agents SHALL no longer include the composite metrics
