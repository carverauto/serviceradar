## ADDED Requirements

### Requirement: Remote-access actions use authoritative readiness
The system SHALL compute readiness for each remote-access action from deployment policy, canonical target identity, registered target or provider target, selected live route, applied agent capability, adapter/helper health, target trust, credential custody, RBAC, and approval state. The browser SHALL NOT make an unavailable action ready by supplying alternate target, route, credential, trust, or recording values.

#### Scenario: Ready SSH action
- **WHEN** SSH is enabled and a device has one authorized registered target, a connected eligible agent route, an applied SSH capability, approved host-key trust, an allowed credential mode, and actor permission
- **THEN** device details exposes a Connect with SSH action bound to those server-selected values

#### Scenario: Dependency is unavailable
- **WHEN** any required readiness dependency is missing, stale, ambiguous, disabled, or unhealthy
- **THEN** the connection action is unavailable and an authorized operator receives a stable sanitized reason code

#### Scenario: Browser attempts to override readiness
- **WHEN** a browser supplies an agent, gateway, upstream host, port, provider reference, credential rule, trust policy, or recording policy that differs from the registered readiness decision
- **THEN** the system rejects the request before issuing a session or credential grant

### Requirement: Protocol readiness requires a deployed proof
The system MUST NOT mark a high-risk graphical or provider-console protocol ready solely because its code compiles, its helper exists, or mocked tests pass. Operational readiness SHALL be a live evaluation over versioned deployment/adapter and target proof evidence rather than a retained success Boolean, intersected with the current actor's authorization and approval state.

Each proof record SHALL bind a schema version, deployment, protocol/action, target and identity revision, endpoint/trust digest, provider resource where applicable, agent/gateway/route and affinity revisions, agent build/applied config, adapter/helper/add-on identity/version/digest/health, graphical renderer/media-contract build where applicable, trust and credential-custody policy revisions, signer/CA revisions where applicable, tested capabilities, result/reason, observation and freshness deadline, evidence digest, and audit reference without secrets.

#### Scenario: Compile-time RDP helper flag
- **WHEN** an RDP helper is linked but has not passed the required live TLS, NLA, media, input, and cleanup proof
- **THEN** the agent does not advertise RDP readiness and the control plane reports the adapter as unready

#### Scenario: Proved protocol becomes available
- **WHEN** the signed adapter, registered target, selected route, target trust, credential policy, browser renderer, and lifecycle pass the controlled proof
- **THEN** the deployment may mark that target and protocol ready without changing secure-off defaults elsewhere

#### Scenario: Bound dependency changes
- **WHEN** feature policy, identity, endpoint/provider relationship, host key/TLS identity, VM placement, route/affinity, agent/gateway/config, adapter/helper/add-on/renderer, credential/CA/recording/approval policy, or proof freshness changes
- **THEN** the bound evidence becomes stale and the action remains unavailable until the required bounded proof succeeds again

#### Scenario: Route reconnects
- **WHEN** a previously proved target route disconnects and later reconnects
- **THEN** the agent capability may recover after self-test but target readiness requires a new bounded target probe

#### Scenario: Browser rendered stale readiness
- **WHEN** a dependency changes after a browser rendered a Connect action
- **THEN** session creation atomically re-evaluates current readiness and rejects the stale launch

### Requirement: Agent capability and target proof are distinct
An agent SHALL advertise a protocol capability only after applied configuration, signed compatible adapter/helper state, and a successful local runtime self-test. A target SHALL remain unavailable until its required route, trust, credential policy, renderer, and controlled target proof are current.

#### Scenario: Agent self-test succeeds without a target proof
- **WHEN** an agent's local adapter self-test succeeds but the registered target has no current controlled proof
- **THEN** the agent may advertise its local capability while the target action remains unavailable

### Requirement: Remote-access failures are sanitized and terminal
Every failed, expired, revoked, route-lost, or abandoned remote-access session SHALL reach a bounded terminal state, release its adapter/helper resources and credential grants, and expose only a typed public failure code to the browser.

#### Scenario: Upstream authentication fails
- **WHEN** an SSH, RDP, or PVE upstream returns a detailed authentication error
- **THEN** the browser and recording receive a sanitized authentication failure code while the redacted internal log retains sufficient diagnostic context

#### Scenario: Session never opens
- **WHEN** a requested or attached session does not become active before its deadline
- **THEN** a reaper closes it, revokes its ticket and credential grant, releases resources, and records the terminal outcome
