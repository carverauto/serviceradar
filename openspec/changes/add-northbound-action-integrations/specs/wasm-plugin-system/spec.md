## ADDED Requirements

### Requirement: Wasm Action Descriptors
Approved Wasm plugin packages SHALL be able to declare versioned northbound action descriptors in their manifest.

Action descriptors SHALL be inactive until the plugin package is approved and SHALL be subject to the same signature, package integrity, capability, allowlist, and resource-budget controls as check and discovery plugins.

#### Scenario: Plugin declares an action descriptor
- **GIVEN** a staged plugin package includes a valid action descriptor
- **WHEN** an admin approves the package and its capabilities
- **THEN** the action descriptor becomes available to the northbound action catalog
- **AND** the descriptor is associated with the approved package version

#### Scenario: Unapproved plugin action is hidden
- **GIVEN** a plugin package includes a valid action descriptor but has not been approved
- **WHEN** the action catalog is refreshed
- **THEN** the plugin action is not launchable

### Requirement: Wasm Action Invocation Entrypoint
The agent Wasm runtime SHALL support an on-demand action invocation entrypoint that receives normalized target context and validated action inputs and returns a structured action result.

#### Scenario: Action invocation succeeds
- **GIVEN** an approved Wasm action provider is assigned to an agent
- **AND** an invocation targets a reachable device
- **WHEN** core dispatches the invocation through the agent command path
- **THEN** the agent executes the plugin action entrypoint under sandbox limits
- **AND** returns a structured action result to core

#### Scenario: Action invocation times out
- **GIVEN** a Wasm action exceeds its descriptor timeout
- **WHEN** the agent enforces the timeout
- **THEN** the action result is marked failed with a timeout classification
- **AND** the agent remains healthy
