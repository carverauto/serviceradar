## ADDED Requirements
### Requirement: Plugin Config Delivery
The agent configuration pipeline SHALL deliver Wasm plugin assignments with package references, schedules, plugin-specific parameters, and engine-wide resource limits.

#### Scenario: Plugin config included in agent response
- **GIVEN** an agent with assigned plugin packages
- **WHEN** it calls `GetConfig`
- **THEN** the response includes a `plugin_config` section with assignments and engine limits
- **AND** each assignment includes package reference, hash, interval, timeout, and parameters

#### Scenario: Config version updates on plugin change
- **GIVEN** an agent with existing plugin assignments
- **WHEN** an assignment is added, removed, or updated
- **THEN** the returned `config_version` changes
- **AND** the agent triggers a plugin config refresh

#### Scenario: Engine limit updates
- **GIVEN** an agent with plugin assignments
- **WHEN** an admin updates the per-agent plugin engine limits
- **THEN** the returned `config_version` changes
- **AND** the agent applies the new limits on the next config refresh
