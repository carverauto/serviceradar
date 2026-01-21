# agent-config Specification

## Purpose
TBD - created by archiving change add-network-sweeper-ui. Update Purpose after archive.
## Requirements
### Requirement: Ash Config Resources

The system SHALL provide Ash resources for managing agent configurations with tenant isolation via Ash context scopes.

#### Scenario: Create config template with tenant scope
- **GIVEN** an admin user with tenant context
- **WHEN** they create a config template via Ash action
- **THEN** the template SHALL be scoped to the tenant
- **AND** the template SHALL not be visible to other tenants

#### Scenario: Config template validation
- **GIVEN** a config template resource
- **WHEN** the template is created or updated
- **THEN** Ash validations SHALL ensure required fields are present
- **AND** JSON schema validation SHALL be applied to template content

#### Scenario: Config instance derives from template
- **GIVEN** a config template and target parameters (agent, partition)
- **WHEN** a config instance is created
- **THEN** the instance SHALL reference the template
- **AND** the instance SHALL store compiled configuration
- **AND** the instance SHALL track version and checksum

---

### Requirement: Config Compilation Pipeline

The system SHALL compile configuration from Ash resources into agent-consumable format with caching and change detection.

#### Scenario: Compile config from database state
- **GIVEN** Ash resources defining a sweep job configuration
- **WHEN** the config compiler is invoked for an agent
- **THEN** the compiler SHALL query relevant Ash resources
- **AND** produce a JSON config matching the agent's expected schema
- **AND** compute a content hash for change detection

#### Scenario: Cache compiled configs
- **GIVEN** a compiled configuration
- **WHEN** no underlying resources have changed
- **THEN** subsequent requests SHALL return the cached config
- **AND** the cache key SHALL include tenant, agent, partition, and config type

#### Scenario: Invalidate cache on resource changes
- **GIVEN** a cached compiled configuration
- **WHEN** an underlying Ash resource is updated
- **THEN** the cache SHALL be invalidated
- **AND** the next request SHALL trigger recompilation

---

### Requirement: Config Distribution Endpoint

The system SHALL expose a gRPC endpoint for agents to poll their compiled configurations from the agent-gateway.

#### Scenario: Agent polls for config
- **GIVEN** an authenticated agent with valid mTLS certificate
- **WHEN** the agent calls `GetConfig(agent_id, config_type, current_hash)`
- **THEN** the gateway SHALL extract tenant from certificate
- **AND** return the compiled config if hash differs from current_hash
- **AND** return `no_change` flag if hashes match

#### Scenario: Gateway forwards to core for compilation
- **GIVEN** an agent config request at the gateway
- **WHEN** the config is not cached at the gateway
- **THEN** the gateway SHALL call core-elx RPC to compile the config
- **AND** cache the result with TTL

#### Scenario: Config type routing
- **GIVEN** multiple config types (sweep, poller, checker)
- **WHEN** an agent requests a specific config type
- **THEN** the appropriate compiler module SHALL be invoked
- **AND** only configs for that type SHALL be returned

---

### Requirement: Event-Driven Config Updates

The system SHALL publish config change events when underlying resources change, enabling reactive cache invalidation and agent notification.

#### Scenario: Resource change triggers event
- **GIVEN** an Ash resource that affects agent config (e.g., SweepJob)
- **WHEN** the resource is created, updated, or deleted
- **THEN** a config change event SHALL be published to NATS
- **AND** the event SHALL include tenant, config_type, and affected agents

#### Scenario: Gateway receives invalidation event
- **GIVEN** a cached config at the agent-gateway
- **WHEN** a config invalidation event is received
- **THEN** the gateway SHALL clear the affected cache entries
- **AND** subsequent agent polls SHALL receive fresh configs

#### Scenario: Agents receive config update notification
- **GIVEN** an agent connected via gRPC stream
- **WHEN** a config change event affects that agent
- **THEN** the gateway MAY push a notification to the agent
- **AND** the agent MAY immediately poll for the new config

---

### Requirement: Config Versioning and Audit

The system SHALL maintain version history and audit trail for configuration changes.

#### Scenario: Config version increment
- **GIVEN** an existing config instance
- **WHEN** the config content changes
- **THEN** the version number SHALL increment
- **AND** the previous version SHALL be retained in history

#### Scenario: Audit trail for config changes
- **GIVEN** a config template or instance
- **WHEN** any modification is made
- **THEN** an audit entry SHALL record the actor, action, timestamp
- **AND** the audit entry SHALL be queryable via Ash

#### Scenario: Rollback to previous version
- **GIVEN** a config instance with version history
- **WHEN** an admin requests rollback to a previous version
- **THEN** the system SHALL restore that version's content
- **AND** increment the version number (not decrement)

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

