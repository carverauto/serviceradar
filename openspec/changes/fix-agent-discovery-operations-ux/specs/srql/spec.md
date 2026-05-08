## ADDED Requirements
### Requirement: Agent host and IP fields
SRQL SHALL expose both `host` and `ip` fields for the `agents` entity. `host` SHALL map to `ocsf_agents.host`, and `ip` SHALL map to `ocsf_agents.ip`.

#### Scenario: Agent host query compiles
- **GIVEN** the deployed `ocsf_agents` table has `host` and `ip` columns
- **WHEN** a user runs `in:agents host:agent-sr-test-pve04`
- **THEN** SRQL SHALL generate SQL that filters `ocsf_agents.host`
- **AND** the query SHALL not filter `ocsf_agents.ip`

#### Scenario: Agent ip query compiles
- **GIVEN** the deployed `ocsf_agents` table has `host` and `ip` columns
- **WHEN** a user runs `in:agents ip:192.168.2.10`
- **THEN** SRQL SHALL generate SQL that filters `ocsf_agents.ip`
- **AND** the query SHALL not fail with an undefined column error
