## ADDED Requirements
### Requirement: Remote access uses the agent control stream
Remote-access commands and frames SHALL use the existing agent-initiated control stream and SHALL NOT require inbound connectivity from the platform to an agent.

#### Scenario: Agent opens outbound control stream
- **GIVEN** an agent has completed Hello and established its control stream
- **WHEN** a remote-access session is assigned to that agent
- **THEN** the gateway SHALL deliver open/data/resize/close frames over that existing stream
- **AND** the platform SHALL NOT dial the agent directly.

### Requirement: Agent enforces session grants
Agents SHALL enforce signed or otherwise authenticated session grants that constrain protocol, target, credential reference, TTL, and session ID.

#### Scenario: Browser cannot retarget SSH connection
- **GIVEN** a session grant authorizes SSH to target `10.1.2.3:22`
- **WHEN** the browser sends terminal input frames
- **THEN** the agent SHALL treat those frames only as terminal input
- **AND** SHALL reject any attempt to change target host, port, protocol, or credential reference after session open.

### Requirement: Credential custody modes for remote access
Agents SHALL support remote-access credentials supplied through explicit custody modes and SHALL fail closed when the required custody mode is unavailable.

#### Scenario: Agent-local SSH key is used
- **GIVEN** a credential rule references an agent-local SSH key
- **WHEN** the agent opens an SSH session
- **THEN** the agent SHALL load the key from its local configured path or secret store
- **AND** the control plane SHALL NOT need the private key material.

#### Scenario: User-present credential is not persisted
- **GIVEN** an operator supplies a password, key, or signing capability for one session
- **WHEN** the session ends or expires
- **THEN** the credential material SHALL be discarded
- **AND** it SHALL NOT be written to the database or agent config.

#### Scenario: Central credential grant is tightly scoped
- **GIVEN** a centrally stored remote-access credential is allowed by policy
- **WHEN** the credential broker issues a grant
- **THEN** the grant SHALL be scoped to one session, one agent, one target, one protocol, and a short TTL
- **AND** the browser SHALL NOT receive plaintext secret material.
