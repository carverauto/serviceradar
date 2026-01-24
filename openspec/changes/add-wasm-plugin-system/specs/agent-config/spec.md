## ADDED Requirements
### Requirement: Plugin Config Delivery
The agent configuration pipeline SHALL deliver Wasm plugin assignments with package references, schedules, and plugin-specific parameters.

#### Scenario: Plugin config included in agent response
- **GIVEN** an agent with assigned plugin packages
- **WHEN** it calls `GetConfig`
- **THEN** the response includes a `plugin_config` section with assignments
- **AND** each assignment includes package reference, hash, interval, timeout, and parameters

#### Scenario: Config version updates on plugin change
- **GIVEN** an agent with existing plugin assignments
- **WHEN** an assignment is added, removed, or updated
- **THEN** the returned `config_version` changes
- **AND** the agent triggers a plugin config refresh
