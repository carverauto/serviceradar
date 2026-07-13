## ADDED Requirements

### Requirement: HPNA credential and assignment configuration
The plugin configuration experience SHALL let an authorized administrator configure an HPNA credential rule, public endpoint/instance metadata, target agent, and plugin assignment without storing plaintext credentials in plugin configuration.

#### Scenario: Administrator configures HPNA collection
- **WHEN** an administrator selects the HPNA provider preset
- **THEN** the UI SHALL collect or reference an encrypted username/password credential, stable instance ID, HTTPS endpoint, and eligible agent scope
- **AND** it SHALL show that credentials are materialized by broker rules at runtime

#### Scenario: No matching credential rule
- **GIVEN** an HPNA assignment targets an agent with no enabled compatible credential rule
- **WHEN** the administrator validates or saves the assignment
- **THEN** the UI SHALL block activation or show an explicit actionable invalid state
- **AND** it SHALL not defer discovery of the missing credential until an opaque runtime failure

### Requirement: Schema-driven HPNA query configuration
The UI SHALL render HPNA query sets and collection bounds from the package config schema, including the default `type=Switch`, and the Ash layer SHALL validate the same schema before saving.

#### Scenario: Default query is displayed
- **WHEN** an administrator creates an HPNA assignment without custom query settings
- **THEN** the form SHALL display one named query with `type=Switch`
- **AND** page size, row limit, and timeout SHALL use documented safe defaults

#### Scenario: Invalid flag is submitted
- **WHEN** configuration includes an unknown flag, plugin-owned pagination key, invalid structured value, or bound outside the schema
- **THEN** save SHALL fail with a field-level error
- **AND** the invalid configuration SHALL not be delivered to the agent

### Requirement: HPNA schedule and run controls
The settings UI SHALL expose the package-declared HPNA producer schedule, enabled state, cadence, target assignment, last/next run, safe status, and Run Now action through generic producer schedule controls.

#### Scenario: Daily schedule is enabled
- **WHEN** an authorized administrator enables the HPNA schedule
- **THEN** the UI SHALL persist the operator schedule separately from the package contract
- **AND** it SHALL show the default daily cadence and next due time

#### Scenario: Viewer attempts Run Now
- **WHEN** a user without producer execution permission attempts to run HPNA collection
- **THEN** ServiceRadar SHALL deny the action
- **AND** no command or credential grant SHALL be created
