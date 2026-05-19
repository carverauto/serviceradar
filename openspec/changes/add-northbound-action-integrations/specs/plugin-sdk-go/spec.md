## ADDED Requirements

### Requirement: Go SDK Action Descriptor APIs
The Go plugin SDK SHALL provide APIs for declaring northbound action descriptors with scopes, required context fields, input schema, timeout, safety metadata, and result schema version.

#### Scenario: Plugin declares a device action
- **GIVEN** a Go Wasm plugin uses the SDK to declare a device-scoped action requiring `device.ip`
- **WHEN** the plugin package manifest is generated or validated
- **THEN** the descriptor is emitted in the expected schema version

### Requirement: Go SDK Action Invocation APIs
The Go plugin SDK SHALL provide helpers to decode action invocation context, read validated inputs, and return structured action results.

#### Scenario: Plugin handles an action invocation
- **GIVEN** the agent invokes a Go Wasm plugin action entrypoint
- **WHEN** the plugin decodes the invocation with the SDK
- **THEN** it can access device and interface target context
- **AND** it can return per-target success or failure results
