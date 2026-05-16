## ADDED Requirements

### Requirement: Sample Northbound Action Example

The Go plugin SDK SHALL include a sample northbound action plugin example that demonstrates device-scoped and interface-scoped action handling without requiring a real external system.

#### Scenario: Example handles device action

- **GIVEN** a developer runs the sample northbound plugin with a device-scoped action invocation fixture
- **WHEN** the plugin decodes the invocation through the Go SDK
- **THEN** it reads the device target context
- **AND** returns a structured per-target result with simulated external API facts

#### Scenario: Example handles interface action

- **GIVEN** a developer runs the sample northbound plugin with an interface-scoped action invocation fixture
- **WHEN** the plugin decodes the invocation through the Go SDK
- **THEN** it reads both device and interface target context
- **AND** returns a structured per-target result with simulated interface/API facts

#### Scenario: Example documents action descriptor shape

- **GIVEN** a developer opens the sample northbound example
- **WHEN** they inspect its manifest and README
- **THEN** the example shows the descriptor fields needed for device and interface actions
- **AND** maps those descriptor fields to SDK invocation/result helpers
