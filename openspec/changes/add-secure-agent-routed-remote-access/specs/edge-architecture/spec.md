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

#### Scenario: Browser target override is disabled by default
- **GIVEN** an operator opens a session for a registered inventory target
- **WHEN** the browser create request supplies a different target host or target port
- **THEN** the public API SHALL reject the request unless the matching target override policy is explicitly enabled
- **AND** the target SHALL default to the inventory target selected by policy.

#### Scenario: Public SSH endpoint cannot request other adapters
- **GIVEN** the public browser endpoint is authorized by the SSH remote-access permission
- **WHEN** the browser create request supplies a non-SSH protocol, non-SSH adapter, or non-inventory target kind
- **THEN** the public API SHALL reject the request before a session ticket is issued
- **AND** future protocol adapters SHALL use a dedicated endpoint or permission check before target access is opened.

### Requirement: Teleport-like access capability coverage
The system SHALL evolve the remote-access tunnel into a ServiceRadar-native access plane with Teleport-like coverage while preserving ServiceRadar ownership of policy, inventory, agent routing, and audit data.

#### Scenario: Capability area is added incrementally
- **GIVEN** a capability such as SSH, session recording, application access, database access, Kubernetes access, desktop/RDP access, or enhanced host tracing is planned
- **WHEN** the capability is implemented
- **THEN** it SHALL reuse the generic session, authorization, audit, credential custody, and agent routing model
- **AND** protocol-specific behavior SHALL remain isolated to an adapter or collector boundary.

#### Scenario: Teleport implementation path is not license clean
- **GIVEN** a Teleport package or source path has AGPL headers or an AGPL transitive dependency path
- **WHEN** ServiceRadar implements equivalent functionality
- **THEN** the implementation SHALL be clean-room and ServiceRadar-authored
- **AND** it SHALL NOT copy, translate, or mechanically port that Teleport implementation source.

### Requirement: Remote access supports multiple protocols
The remote-access tunnel SHALL separate session lifecycle and routing from protocol-specific adapters and browser renderers.

#### Scenario: SSH and RDP use shared session lifecycle
- **GIVEN** SSH uses an xterm renderer and future RDP uses a graphical renderer
- **WHEN** either session is created
- **THEN** both SHALL use the same RBAC, audit, TTL, gateway routing, and agent ownership model
- **AND** only protocol adapter and browser renderer behavior SHALL differ.

#### Scenario: Generic SSH uses session-present credentials before certificate issuance is available
- **GIVEN** an operator opens an SSH terminal for a general inventory device
- **WHEN** short-lived certificate issuance is not yet available for that target
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

#### Scenario: Recording manifest tracks retention without plaintext defaults
- **GIVEN** session recording is enabled by policy
- **WHEN** a remote-access session opens, exchanges terminal data, and closes
- **THEN** the system SHALL persist a recording manifest with storage pointer, retention expiry, lifecycle status, and aggregate input/output byte counters
- **AND** raw terminal byte contents SHALL NOT be persisted unless a separate explicit content-recording policy permits it.

### Requirement: Generic SSH uses certificate-first enterprise identity
Generic SSH remote access SHALL support an enterprise certificate flow where ServiceRadar exchanges an authenticated SSO identity and ServiceRadar RBAC decision for a short-lived OpenSSH user certificate.

#### Scenario: Authentik-backed user opens SSH session
- **GIVEN** an operator authenticated through Authentik with OIDC or SAML claims
- **AND** ServiceRadar RBAC maps those claims to allowed SSH principals for a registered target
- **AND** the target trusts the ServiceRadar SSH user CA through OpenSSH `TrustedUserCAKeys`
- **WHEN** the operator opens an SSH remote-access session
- **THEN** ServiceRadar SHALL sign a per-session public key with a TTL bounded by session and role policy
- **AND** the certificate SHALL be scoped to the actor, principal set, target, selected agent, protocol, and session
- **AND** no shared bastion account, reusable target password, generic agent-local target private key, or LDAP password pass-through secret SHALL be required.

#### Scenario: Certificate issuance is denied before target dial
- **GIVEN** the requested principal, target, agent route, approval, MFA state, or TTL violates policy
- **WHEN** the operator attempts to open an SSH session
- **THEN** ServiceRadar SHALL deny certificate issuance before the selected agent dials the target
- **AND** the denial SHALL be audited without exposing credential material.

### Requirement: Enhanced host-event tracing
The system SHALL support policy-controlled enhanced tracing for remote-access sessions on capable Linux agents.

#### Scenario: BPF tracing is required by policy
- **GIVEN** a remote-access policy requires enhanced tracing
- **AND** the selected agent cannot start the required BPF collectors
- **WHEN** the operator starts the session
- **THEN** the session SHALL fail before target access is opened
- **AND** the failure SHALL be audited with a sanitized reason.

#### Scenario: BPF tracing records session-correlated events
- **GIVEN** enhanced tracing is enabled for an active session
- **WHEN** commands execute, files are opened, or network connections are attempted from the session context
- **THEN** the agent SHALL emit normalized events correlated to the remote-access session
- **AND** the events SHALL include dropped-event counters when kernel or user-space buffers lose data
- **AND** the events SHALL NOT include plaintext credentials, terminal input bytes, or file contents.
