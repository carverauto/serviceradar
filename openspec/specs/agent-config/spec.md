# agent-config Specification

## Purpose
Management, distribution, and derivation of edge agent configurations, plugin credentials, and capability bindings.

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

### Requirement: Plugin credential grants are resolved at use
For plugin assignments delivered to an agent that advertises the `credential_broker_resolve_by_binding` capability, the agent config SHALL carry each credential binding's scope and identity but no credential-broker grant id, and core SHALL authorize, reuse or mint, and resolve the grant when the agent requests credential material for that binding.

#### Scenario: Capable agent resolves by binding
- **GIVEN** an enabled policy assignment for agent `agent-a` with credential binding `b1`
- **AND** `agent-a` advertised `credential_broker_resolve_by_binding`
- **WHEN** `agent-a` requests material with assignment id and binding id `b1`
- **THEN** core SHALL authorize against the current assignment and binding
- **AND** it SHALL reuse a live grant of identical scope or issue one through the grant issue action
- **AND** the delivered config SHALL NOT contain a grant id for `b1`

#### Scenario: Grant rotation does not change config
- **GIVEN** a capable agent whose binding's grant has been reissued
- **WHEN** its config is generated again
- **THEN** the config version SHALL be unchanged

#### Scenario: Authorization follows the current assignment
- **GIVEN** binding `b1`'s credential rule has been disabled or its secret changed
- **WHEN** the agent requests material for `b1`
- **THEN** core SHALL deny the request and record a denial audit
- **AND** it SHALL NOT issue a grant

#### Scenario: Foreign agent cannot resolve a binding
- **GIVEN** assignment `p1` belongs to agent `agent-a`
- **WHEN** agent `agent-b` requests material for a binding of `p1`
- **THEN** core SHALL deny the request

### Requirement: Legacy agents keep embedded plugin grants
For an agent that has not advertised `credential_broker_resolve_by_binding`, config generation SHALL embed a credential-broker grant per binding as before, and SHALL reuse a live grant of identical scope instead of issuing a new grant on every generation.

#### Scenario: Legacy agent keeps working
- **GIVEN** an agent that does not advertise the capability
- **WHEN** its config is generated
- **THEN** each credential binding SHALL carry a grant the agent can resolve by grant id

#### Scenario: Repeated generation reuses the grant
- **GIVEN** a live grant already issued for a legacy agent's binding scope
- **WHEN** the agent's config is generated again before that grant nears expiry
- **THEN** the same grant SHALL be delivered

### Requirement: Credential reconcile does not mint grants
The credential-rule reconcile that materializes plugin assignments SHALL record each binding's grant scope in the assignment template and SHALL NOT issue a credential-broker grant.

#### Scenario: Reconcile cycle issues no grant
- **GIVEN** an unchanged credential rule and its existing assignment
- **WHEN** the reconcile runs
- **THEN** no credential-broker grant SHALL be issued
