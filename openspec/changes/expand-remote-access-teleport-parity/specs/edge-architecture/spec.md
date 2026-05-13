## ADDED Requirements
### Requirement: Teleport-like parity expands through scoped protocol proposals
ServiceRadar SHALL expand Teleport-like remote-access parity through scoped protocol and governance proposals that preserve route binding, credential custody, RBAC, audit, recording policy, and license-review guardrails.

#### Scenario: Protocol adapter is proposed before implementation
- **GIVEN** a new remote-access protocol adapter such as file transfer, application/TCP, database, Kubernetes, desktop/RDP, cloud/API, MCP, vSphere, or OT is planned
- **WHEN** implementation work is requested
- **THEN** the change SHALL define the protocol name, target resource type, selected-agent route model, RBAC permissions, approval triggers, credential custody mode, recording/export policy, quota/backpressure behavior, validation tests, demo proof path, and Teleport/source reuse license notes before code lands.

#### Scenario: Feature cannot use arbitrary client-selected routing
- **GIVEN** a browser or API client requests a Teleport-like remote-access feature
- **WHEN** the feature opens a target connection through an enrolled agent
- **THEN** ServiceRadar SHALL derive the route, upstream target, credential rule, recording policy, and approval requirement from trusted inventory or policy
- **AND** SHALL reject client-supplied values that would turn the agent into an arbitrary TCP bounce.

### Requirement: Teleport parity status remains explicit
ServiceRadar SHALL maintain a Teleport capability matrix that distinguishes implemented foundation features from planned, out-of-scope, license-blocked, and approval-required parity areas.

#### Scenario: Foundation PR merges before full parity
- **GIVEN** the SSH and agent-routed remote-access foundation is ready to merge
- **WHEN** broader Teleport-like features remain incomplete
- **THEN** the active parity matrix SHALL show those features as planned or not implemented
- **AND** the foundation change SHALL NOT be described as full Teleport parity.
