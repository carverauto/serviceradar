## ADDED Requirements

### Requirement: Add-On Profile Actions Use Structured Ash Context
Native add-on profile preview and reconcile actions SHALL use Ash action context as a structured context value and SHALL NOT assume it implements the Access behaviour.

#### Scenario: Reconcile action receives actor context
- **GIVEN** an authenticated operator invokes add-on profile reconciliation
- **WHEN** Ash calls the resource action implementation with an `Ash.Resource.Actions.Implementation.Context`
- **THEN** the action SHALL read the actor from the structured context
- **AND** it SHALL return a normal success or error tuple instead of raising an `UndefinedFunctionError`

#### Scenario: Preview action receives actor context
- **GIVEN** an authenticated operator previews an add-on profile
- **WHEN** Ash calls the resource action implementation with an `Ash.Resource.Actions.Implementation.Context`
- **THEN** the action SHALL read the actor from the structured context
- **AND** authorization and scoping SHALL be preserved

### Requirement: Endpoint Inventory Profile Reconcile Report
The agent configuration system SHALL produce a structured reconcile report for endpoint inventory add-on profiles.

#### Scenario: Reconcile reports all target stages
- **GIVEN** an enabled endpoint inventory profile with target query `in:devices`
- **WHEN** profile reconciliation runs
- **THEN** the report SHALL include matched row count, resolved device count, resolved agent count, eligible agent count, assignment count, and skipped target count
- **AND** each skipped target SHALL include a stable machine-readable reason

#### Scenario: Reconcile respects package compatibility
- **GIVEN** a profile matches an agent whose platform, architecture, base agent version, or capabilities do not satisfy the endpoint inventory package requirements
- **WHEN** profile reconciliation runs
- **THEN** the system SHALL NOT materialize an endpoint inventory assignment for that agent
- **AND** the reconcile report SHALL record the compatibility failure

#### Scenario: Reconcile records manual override
- **GIVEN** a profile matches an agent with a manual endpoint inventory assignment override
- **WHEN** profile reconciliation runs
- **THEN** the profile SHALL NOT overwrite the manual override
- **AND** the reconcile report SHALL record that profile ownership was skipped due to manual override

### Requirement: Endpoint Inventory Config Delivery State
The agent configuration system SHALL expose enough state to determine whether a profile-derived endpoint inventory assignment has reached an agent config response.

#### Scenario: Assignment included in agent config
- **GIVEN** a profile materializes an endpoint inventory assignment for an eligible agent
- **WHEN** the agent receives its next config response through agent-gateway
- **THEN** the system SHALL record or expose the assignment config hash/version associated with that response
- **AND** the UI SHALL be able to distinguish materialized-but-not-yet-delivered from delivered configuration

#### Scenario: Agent lacks control stream
- **GIVEN** a profile materializes an endpoint inventory assignment for an agent whose control stream is offline
- **WHEN** an operator inspects profile coverage
- **THEN** the system SHALL report the assignment as pending delivery due to offline control stream
