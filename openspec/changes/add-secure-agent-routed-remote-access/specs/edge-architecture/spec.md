## ADDED Requirements
### Requirement: Agent-routed remote access tunnel
The system SHALL provide a generic remote-access tunnel that routes operator sessions through web-ng, agent-gateway, and the selected edge agent before connecting to the target.

#### Scenario: Reach target only visible to an edge agent
- **GIVEN** a target device is reachable from agent `A` but not directly from the platform
- **AND** an operator is authorized for remote access to that target
- **WHEN** the operator starts a remote access session
- **THEN** web-ng SHALL create a session bound to agent `A`
- **AND** agent-gateway SHALL route frames over agent `A`'s authenticated control stream
- **AND** agent `A` SHALL open the protocol-specific connection to the target.

#### Scenario: Overlapping networks remain agent-scoped
- **GIVEN** two agents can each reach a target at `192.168.1.10` in different networks
- **WHEN** an operator opens a session for a specific inventory target
- **THEN** the session SHALL be bound to the agent selected by policy or inventory relationship
- **AND** target host/port/protocol SHALL NOT be retargetable by browser-supplied frame data.

### Requirement: Remote access supports multiple protocols
The remote-access tunnel SHALL separate session lifecycle and routing from protocol-specific adapters and browser renderers.

#### Scenario: SSH and RDP use shared session lifecycle
- **GIVEN** SSH uses an xterm renderer and future RDP uses a graphical renderer
- **WHEN** either session is created
- **THEN** both SHALL use the same RBAC, audit, TTL, gateway routing, and agent ownership model
- **AND** only protocol adapter and browser renderer behavior SHALL differ.

#### Scenario: Generic SSH uses session-present or agent-local credentials
- **GIVEN** an operator opens an SSH terminal for a general inventory device
- **WHEN** no approved agent-local credential exists for that device
- **THEN** the browser SHALL collect the private key or password for that session only
- **AND** the platform SHALL forward it through the remote-access tunnel without persisting it in core, gateway, database, object storage, or plugin configuration
- **AND** the agent SHALL discard the credential when the session ends.

#### Scenario: Proxmox console does not require SSH keys
- **GIVEN** an operator opens a Proxmox node, LXC, or VM console
- **WHEN** the selected agent has an authorized Proxmox API credential grant
- **THEN** the Proxmox adapter SHALL request a temporary provider console ticket or proxy endpoint from the Proxmox API
- **AND** it SHALL route that console stream through the generic remote-access tunnel without requiring or storing SSH private keys.

#### Scenario: OT protocol adapter can be added later
- **GIVEN** a future OT integration needs CEA-852/CN-IP access to LonTalk networks through an edge agent
- **WHEN** representative test data or equipment is available
- **THEN** the adapter SHALL reuse the generic remote-access session, RBAC, audit, and agent routing model
- **AND** CEA-852-specific UDP/TCP framing and validation SHALL remain isolated to the protocol adapter.

#### Scenario: CEA-852 starts as read-only diagnostics
- **GIVEN** CEA-852/CN-IP can expose building-management systems to disruptive packet types and weak/default authentication conditions
- **WHEN** ServiceRadar first adds CEA-852 support
- **THEN** the adapter SHALL be limited to passive capture parsing or read-only diagnostics by default
- **AND** active packet crafting, reboot/configuration operations, or credential/key changes SHALL require a separate approved proposal, lab validation, explicit policy enablement, and audit coverage.

### Requirement: Remote access auditability
The system SHALL record audit events for remote-access session lifecycle and policy decisions without storing plaintext credentials or terminal byte contents by default.

#### Scenario: Session is audited
- **WHEN** a remote-access session is created, attached, resized, closed, expires, or fails
- **THEN** the audit event SHALL include actor, target, selected agent, protocol, credential rule or custody mode, RBAC/approval result, timestamps, and terminal outcome
- **AND** the audit event SHALL NOT include plaintext credentials.

#### Scenario: Session recording is policy controlled
- **GIVEN** session recording is disabled by policy
- **WHEN** operators use a remote shell
- **THEN** terminal byte contents SHALL NOT be persisted
- **AND** lifecycle audit events SHALL still be recorded.

#### Scenario: Enhanced Linux recording captures structured activity
- **GIVEN** a remote-access session runs through a Linux agent with compatible eBPF support
- **AND** policy enables enhanced recording for that target and protocol
- **WHEN** the session starts
- **THEN** the agent SHALL bind enhanced telemetry to the ServiceRadar session ID
- **AND** it SHALL emit configured command, file, and/or network events as structured audit/security events
- **AND** it SHALL report lost-event counters and initialization failures.

#### Scenario: Enhanced recording failure policy is explicit
- **GIVEN** enhanced Linux recording is required by policy for a privileged session
- **WHEN** the selected agent cannot initialize the required recording hooks
- **THEN** the session SHALL follow the policy failure mode, either denying or terminating the session for `strict` policy, or continuing with lifecycle/terminal recording only for `best_effort` policy
- **AND** the failure SHALL be audited.
