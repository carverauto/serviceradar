## ADDED Requirements

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
