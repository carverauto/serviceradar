## MODIFIED Requirements

### Requirement: Plugin credential grants are resolved at use
For plugin assignments delivered to an agent that advertises the `credential_broker_resolve_by_binding` capability, the agent config SHALL carry each credential binding's scope and identity but no credential-broker grant id, and core SHALL authorize, reuse or mint, and resolve the grant when the agent requests credential material for that binding. A Proxmox host-authority binding's `binding_id` SHALL derive solely from the assignment id, credential secret id, canonical controller origin, auth method, and TLS verification setting, remaining stable across sibling target-set changes and per-device inventory metadata updates, while core SHALL verify separately against the current assignment's live target scope that at least one live target still maps to that binding before issuing or resolving a grant.

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

#### Scenario: Binding identity survives target-set and device-metadata updates while target remains in live scope
- **GIVEN** an enabled Proxmox policy assignment for `agent-a` delivering binding `b1` for controller origin `https://192.0.2.10:8006`
- **WHEN** sibling targets are added or removed or the target's `device_uid` or provider metadata changes while at least one live target in the assignment still resolves to `b1`'s authority scope
- **THEN** `b1`'s `binding_id` SHALL remain unchanged
- **AND** core SHALL authorize and resolve `agent-a`'s credential request for `b1`

#### Scenario: Target removed from live scope is denied even with a previously issued binding id
- **GIVEN** `agent-a` holds binding id `b1` for controller origin `https://192.0.2.10:8006` from an earlier config
- **WHEN** the assignment's live target scope changes so no live target resolves to `b1`'s authority scope and `agent-a` requests material for `b1`
- **THEN** core SHALL deny the request and record a denial audit
- **AND** it SHALL NOT issue a grant

#### Scenario: Authorization follows the current assignment
- **GIVEN** binding `b1`'s credential rule has been disabled or its secret changed
- **WHEN** the agent requests material for `b1`
- **THEN** core SHALL deny the request and record a denial audit
- **AND** it SHALL NOT issue a grant

#### Scenario: Foreign agent cannot resolve a binding
- **GIVEN** assignment `p1` belongs to agent `agent-a`
- **WHEN** agent `agent-b` requests material for a binding of `p1`
- **THEN** core SHALL deny the request
