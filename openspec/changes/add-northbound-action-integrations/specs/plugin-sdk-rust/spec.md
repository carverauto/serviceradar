## ADDED Requirements

### Requirement: Rust SDK Action Descriptor APIs
The Rust plugin SDK SHALL provide APIs for declaring northbound action descriptors with scopes, required context fields, input schema, timeout, safety metadata, and result schema version.

#### Scenario: Plugin declares an interface action
- **GIVEN** a Rust Wasm plugin uses the SDK to declare an interface-scoped action requiring `device.ip` and `interface.name`
- **WHEN** the plugin package manifest is generated or validated
- **THEN** the descriptor is emitted in the expected schema version

### Requirement: Rust SDK Action Invocation APIs
The Rust plugin SDK SHALL provide helpers to decode action invocation context, read validated inputs, and return structured action results.

#### Scenario: Plugin returns per-target results
- **GIVEN** the agent invokes a Rust Wasm plugin action entrypoint with multiple interface targets
- **WHEN** the plugin completes
- **THEN** the SDK can serialize per-target action results in the expected schema version
