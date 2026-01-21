## ADDED Requirements

### Requirement: Mapper discovery config delivery
The system SHALL compile mapper discovery jobs into an agent-consumable config and deliver it via the agent-gateway `GetConfig` endpoint using a dedicated config type.

#### Scenario: Agent polls for mapper config
- **GIVEN** an authenticated agent with mapper discovery enabled
- **WHEN** the agent calls `GetConfig` with `config_type = mapper` and its current hash
- **THEN** the gateway SHALL return the compiled mapper config when the hash differs
- **AND** return `no_change` when the hash matches

#### Scenario: Core compiles mapper config from Ash resources
- **GIVEN** mapper discovery jobs and credentials stored as Ash resources
- **WHEN** the gateway requests mapper config from core-elx
- **THEN** core SHALL compile the jobs into the mapper config schema
- **AND** include job schedules, seed targets, and credential references

#### Scenario: Config caching respects mapper updates
- **GIVEN** a cached mapper config at the gateway
- **WHEN** a mapper discovery job is created, updated, or deleted
- **THEN** a config invalidation event SHALL clear the cached mapper config
- **AND** the next agent poll SHALL receive the updated config
