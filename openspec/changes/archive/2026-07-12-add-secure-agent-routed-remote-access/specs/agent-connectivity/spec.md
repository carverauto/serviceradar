## ADDED Requirements
### Requirement: Remote access uses the agent control stream
Remote-access commands and frames SHALL use the existing agent-initiated control stream and SHALL NOT require inbound connectivity from the platform to an agent.

#### Scenario: Agent opens outbound control stream
- **GIVEN** an agent has completed Hello and established its control stream
- **WHEN** a remote-access session is assigned to that agent
- **THEN** the gateway SHALL deliver open/data/resize/close frames over that existing stream
- **AND** the platform SHALL NOT dial the agent directly.

### Requirement: Bound remote-access instructions are enforced end to end
The control plane SHALL enforce session authorization and expiry and bind protocol, registered target, selected agent/gateway route, and credential custody before dispatch. The selected agent SHALL accept frames only for that bound session and route and SHALL reject retargeting after open.

#### Scenario: Browser cannot retarget SSH connection
- **GIVEN** a session grant authorizes SSH to target `10.1.2.3:22`
- **WHEN** the browser sends terminal input frames
- **THEN** the agent SHALL treat those frames only as terminal input
- **AND** SHALL reject any attempt to change target host, port, protocol, or credential reference after session open.

#### Scenario: SSH open payload cannot change selected route
- **GIVEN** an SSH open frame is delivered over an authenticated route for agent `agent-a` and gateway `gateway-a`
- **WHEN** the payload declares a different `agent_id` or `gateway_id`
- **THEN** the agent SHALL reject the open frame before dialing the target
- **AND** no SSH credential material SHALL be used.

### Requirement: Credential custody modes for remote access
Agents SHALL support remote-access credentials supplied through explicit custody modes and SHALL fail closed when the required custody mode is unavailable.

#### Scenario: User-present credential is not persisted
- **GIVEN** an operator supplies a password, key, or signing capability for one session
- **WHEN** the session ends or expires
- **THEN** the credential material SHALL be discarded
- **AND** it SHALL NOT be written to the database or agent config.

#### Scenario: Central credential grant is tightly scoped
- **GIVEN** a centrally stored remote-access credential is explicitly allowed by break-glass or non-SSH-device policy
- **WHEN** the credential broker issues a grant
- **THEN** the grant SHALL be scoped to one session, one selected agent/gateway route, one target, one protocol, and a short TTL
- **AND** the browser SHALL NOT receive plaintext secret material.

#### Scenario: Protocol rejects mismatched custody mode
- **GIVEN** a protocol uses a specific credential custody model
- **WHEN** a session request supplies a custody mode intended for a different protocol
- **THEN** the control plane SHALL reject the session before issuing an attach ticket
- **AND** generic SSH SHALL NOT accept provider-ticket or no-credential custody modes.
