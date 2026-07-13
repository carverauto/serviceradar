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
- **AND** browser create requests SHALL NOT select or override the agent or gateway route
- **AND** target host/port/protocol SHALL NOT be retargetable by browser-supplied frame data.

#### Scenario: Browser target override is disabled by default
- **GIVEN** an operator opens a session for a registered inventory target
- **WHEN** the browser create request supplies a different target host or target port
- **THEN** the public API SHALL reject the request unless the matching target override policy is explicitly enabled
- **AND** the target SHALL default to the inventory target selected by policy.

#### Scenario: Enabled target port override is range checked
- **GIVEN** target-port override policy is explicitly enabled
- **WHEN** the browser create request supplies a target port outside the valid TCP port range
- **THEN** the public API SHALL reject the request before a session ticket is issued.

#### Scenario: Public SSH endpoint cannot request other adapters
- **GIVEN** the public browser endpoint is authorized by the SSH remote-access permission
- **WHEN** the browser create request supplies a non-SSH protocol, non-SSH adapter, or non-inventory target kind
- **THEN** the public API SHALL reject the request before a session ticket is issued
- **AND** future protocol adapters SHALL use a dedicated endpoint or permission check before target access is opened.

#### Scenario: Terminal dimensions are bounded
- **WHEN** the browser create request, attach frame, or resize frame supplies terminal dimensions
- **THEN** the browser-facing boundary SHALL require integer columns and rows within deployment-safe bounds
- **AND** malformed terminal payloads SHALL be rejected before opening or resizing the agent-side adapter.

#### Scenario: Browser terminal data frames are bounded
- **WHEN** the browser sends terminal or protocol data frames
- **THEN** the browser-facing stream SHALL reject frames above the deployment-safe payload size before forwarding to the broker
- **AND** oversized data frames SHALL fail the session with a sanitized error.

#### Scenario: Agent control frames are independently bounded
- **WHEN** the selected agent receives remote-access open, data, or resize frames from the control stream
- **THEN** the agent-side session manager SHALL reject oversized open payloads, oversized terminal data, and invalid terminal dimensions before opening or writing to the target PTY
- **AND** invalid active-session frames SHALL close the session with a sanitized error frame.

#### Scenario: Agent output frames are bounded
- **WHEN** a target PTY adapter returns terminal output larger than the deployment-safe frame size
- **THEN** the agent-side session manager SHALL split the output into bounded data frames before forwarding it to the control stream
- **AND** the split output SHALL preserve byte order.

#### Scenario: SSH adapter inputs are bounded
- **WHEN** the SSH adapter decodes an open frame
- **THEN** it SHALL reject invalid target ports and oversized target, terminal, username, credential, certificate, password, or passphrase fields before dialing
- **AND** rejected SSH adapter input SHALL NOT invoke the dialer.

#### Scenario: Proxmox SSH compatibility inputs are bounded
- **WHEN** the legacy Proxmox SSH compatibility connector receives SSH target or credential config
- **THEN** it SHALL reject invalid target ports and oversized target, username, private key, password, or passphrase fields before dialing
- **AND** rejected compatibility input SHALL NOT invoke the dialer.

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
- **THEN** user-present custody SHALL supply the private key or password to the current attach flow
- **AND** the platform SHALL forward it through the remote-access tunnel without persisting it in core, gateway, database, object storage, or plugin configuration
- **AND** any explicitly policy-enabled client-only remembered-key storage SHALL remain outside platform custody
- **AND** the agent SHALL discard the credential when the session ends.

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

### Requirement: Future protocol adapters require approved proposals
Future app, database, Kubernetes, desktop/RDP, vSphere console, and OT adapters SHALL require per-protocol OpenSpec proposals and threat models before implementation.

#### Scenario: Adapter proposal defines the security contract
- **WHEN** ServiceRadar adds a new remote-access protocol adapter
- **THEN** the adapter proposal SHALL define protocol name, target resource type, agent capability flag, RBAC permissions, approval triggers, credential custody mode, recording policy, quota behavior, validation tests, demo proof path, and Teleport/source reuse license notes
- **AND** implementation SHALL NOT start until the proposal is approved.

#### Scenario: App access is not an open proxy
- **WHEN** ServiceRadar adds HTTP or HTTPS application access
- **THEN** the adapter SHALL route only to registered targets selected by trusted policy
- **AND** it SHALL reject arbitrary browser-supplied upstream hosts, routes, credentials, or CONNECT tunnel behavior unless a dedicated approved policy enables that behavior
- **AND** it SHALL define Host/SNI, header, origin-isolation, upstream TLS, request audit, and upload/download content boundaries.

#### Scenario: Database access protects query and result data
- **WHEN** ServiceRadar adds database access
- **THEN** the adapter SHALL avoid broad shared database credentials by preferring short-lived credentials, mTLS, or one-session broker grants
- **AND** it SHALL define read-only policy, query/result-size quotas, metadata recording, query redaction, and destructive-operation controls before target access opens.

#### Scenario: Kubernetes access preserves actor identity
- **WHEN** ServiceRadar adds Kubernetes API, exec, logs, or port-forward access
- **THEN** the adapter SHALL preserve the ServiceRadar actor through impersonation or short-lived client identity
- **AND** namespace, resource, verb, exec, and port-forward permissions SHALL be policy scoped
- **AND** bearer tokens, kubeconfigs, and client private keys SHALL NOT be persisted in recordings, audit events, or browser-visible metadata.

#### Scenario: Desktop and RDP access gates redirection features
- **WHEN** ServiceRadar adds graphical desktop or RDP access
- **THEN** clipboard, drive, printer, audio, smart-card, and file redirection SHALL be disabled by default
- **AND** each redirection feature SHALL require explicit RBAC and policy enablement
- **AND** screen recording, screenshot, frame-rate, bitrate, and credential-prompt handling SHALL be defined before production access.

#### Scenario: Provider console adapters use provider tickets
- **WHEN** ServiceRadar adds vSphere or similar provider-console access
- **THEN** the adapter SHALL use short-lived provider-issued console tickets or one-session provider grants
- **AND** provider API credentials and console tickets SHALL NOT be stored in browser request bodies, session metadata, recordings, or replay events
- **AND** power or configuration operations SHALL require a separate approved proposal.

### Requirement: Remote access auditability
The system SHALL record audit events for remote-access session lifecycle and policy decisions without storing plaintext credentials or terminal byte contents by default.

#### Scenario: Session is audited
- **WHEN** a remote-access session is created, attached, resized, closed, expires, or fails
- **THEN** a correlated lifecycle audit trail SHALL preserve actor and RBAC/approval context for creation, attach, and denial decisions and SHALL preserve target, selected route, protocol, non-secret custody decision, timestamps, and terminal outcome for broker lifecycle events
- **AND** the correlated audit records SHALL NOT include plaintext credentials.

#### Scenario: Browser metadata cannot carry credentials
- **WHEN** a browser create request includes credential-shaped metadata such as private keys, passwords, passphrases, tickets, tokens, or secrets
- **THEN** the public API SHALL remove those fields before requesting a session
- **AND** only non-sensitive metadata SHALL be forwarded to the session lifecycle.

#### Scenario: Attach credential envelope is bounded
- **WHEN** the browser attach frame supplies SSH credential material
- **THEN** the browser-facing boundary SHALL reject oversized credential fields before starting the broker
- **AND** client-supplied identity claims, principal mappings, target routing fields, or credential-policy fields SHALL NOT be accepted from the credential envelope.

#### Scenario: Session recording is policy controlled
- **GIVEN** session recording is disabled by policy
- **WHEN** operators use a remote shell
- **THEN** terminal byte contents SHALL NOT be persisted
- **AND** lifecycle audit events SHALL still be recorded.

#### Scenario: Browser cannot choose recording policy
- **WHEN** the browser create request supplies recording or enhanced-recording policy fields
- **THEN** the public API SHALL reject the request before a session ticket is issued
- **AND** recording policy SHALL be selected only by trusted remote-access policy.

#### Scenario: Browser cannot choose credential rules
- **WHEN** the browser create request supplies a credential rule ID
- **THEN** the public API SHALL reject the request before a session ticket is issued
- **AND** credential rule selection SHALL be selected only by trusted remote-access policy.

#### Scenario: Recording manifest tracks retention without plaintext defaults
- **GIVEN** session recording is enabled by policy
- **WHEN** a remote-access session opens, exchanges terminal data, and closes
- **THEN** the system SHALL persist a recording manifest with retention expiry, lifecycle status, aggregate input/output byte counters, and optional storage-reference metadata
- **AND** raw terminal byte contents SHALL NOT be persisted unless a separate explicit content-recording policy permits it.
