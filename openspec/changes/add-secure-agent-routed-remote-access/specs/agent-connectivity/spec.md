## ADDED Requirements
### Requirement: Remote access uses the agent control stream
Remote-access commands and frames SHALL use the existing agent-initiated control stream and SHALL NOT require inbound connectivity from the platform to an agent.

#### Scenario: Agent opens outbound control stream
- **GIVEN** an agent has completed Hello and established its control stream
- **WHEN** a remote-access session is assigned to that agent
- **THEN** the gateway SHALL deliver open/data/resize/close frames over that existing stream
- **AND** the platform SHALL NOT dial the agent directly.

### Requirement: Agents advertise remote-access capabilities
Agents SHALL advertise remote-access adapter and enhanced-recording capabilities during enrollment and control-stream heartbeats.

#### Scenario: Agent lacks BPF support
- **GIVEN** an agent is running on a platform without compatible BPF support
- **WHEN** it sends Hello or a control-stream heartbeat
- **THEN** it SHALL omit `remote_access.bpf`
- **AND** the control plane SHALL NOT route sessions requiring enhanced BPF tracing to that agent.

#### Scenario: BPF capability requires explicit production gate
- **GIVEN** the agent has a ServiceRadar-owned BPF collector implementation
- **WHEN** BPF runtime enablement is disabled, the kernel compatibility check fails, required BPF filesystem paths are unavailable, required eBPF features are unsupported, permissions are insufficient, or the self-test collection cannot load
- **THEN** the agent SHALL omit `remote_access.bpf`
- **AND** the capability report SHALL preserve sanitized disabled reasons for operator diagnosis.

#### Scenario: Procfs fallback does not advertise BPF
- **GIVEN** an agent can collect fallback host events from procfs or another non-BPF source
- **WHEN** the agent advertises remote-access capabilities
- **THEN** fallback collection MAY advertise generic recording capability
- **AND** it SHALL NOT advertise `remote_access.bpf`.

#### Scenario: Required BPF policy fails before target dial
- **GIVEN** a remote-access session policy requires BPF enhanced recording
- **AND** the selected agent cannot start the required ServiceRadar-owned BPF collector for that session
- **WHEN** the agent receives the open frame
- **THEN** it SHALL fail the session before opening the target connection
- **AND** the target opener SHALL NOT be invoked.

#### Scenario: Agentless target cannot satisfy required BPF
- **GIVEN** a remote-access session targets a host where ServiceRadar cannot attach managed host probes
- **WHEN** policy requires BPF enhanced recording
- **THEN** the session SHALL fail closed before target access
- **AND** fallback collectors SHALL be used only when policy explicitly allows fallback.

### Requirement: Agent enforces session grants
Agents SHALL enforce signed or otherwise authenticated session grants that constrain protocol, target, credential reference, TTL, session ID, and selected agent/gateway route.

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

#### Scenario: SSO identity is exchanged for a short-lived SSH certificate
- **GIVEN** an operator authenticated to ServiceRadar through an OIDC/SAML identity provider such as Authentik
- **AND** ServiceRadar RBAC allows the operator to assume one or more SSH principals on a target
- **WHEN** the operator opens a generic SSH remote-access session
- **THEN** ServiceRadar SHALL be able to issue a short-lived OpenSSH user certificate scoped to that actor, target, principal set, and session
- **AND** the selected agent SHALL use the certificate for SSH authentication without storing a reusable target password or shared bastion private key.

#### Scenario: Protocol rejects mismatched custody mode
- **GIVEN** a protocol uses a specific credential custody model
- **WHEN** a session request supplies a custody mode intended for a different protocol
- **THEN** the control plane SHALL reject the session before issuing an attach ticket
- **AND** generic SSH SHALL NOT accept provider-ticket or no-credential custody modes.
