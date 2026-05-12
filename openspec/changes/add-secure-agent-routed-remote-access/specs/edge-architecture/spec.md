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

### Requirement: Remote access manages SSH host-key trust
The system SHALL maintain auditable SSH host-key trust state for agent-routed remote access without storing reusable login credentials.

#### Scenario: Trust-on-first-use host key is collected
- **GIVEN** the selected agent observes an unknown SSH host key for a remote-access target
- **WHEN** the session uses trust-on-first-use policy and no trusted key exists for the same agent-scoped target
- **THEN** the control plane SHALL record the key fingerprint, target, selected agent, lifecycle status, first seen time, and last seen time
- **AND** the record SHALL be trusted without storing user credentials or target login secrets.

#### Scenario: Host-key conflict is detected
- **GIVEN** a remote-access target already has a trusted SSH host key
- **WHEN** the selected agent observes a different key for the same agent-scoped target
- **THEN** the control plane SHALL record the new key as a conflict
- **AND** the conflict SHALL be auditable before an operator trusts, revokes, or rotates the key.

#### Scenario: Host-key rotation is audited
- **GIVEN** an operator approves a replacement key for the same agent-scoped target
- **WHEN** the host-key management API rotates the trusted key
- **THEN** the prior key SHALL be marked rotated with a replacement reference
- **AND** the replacement key SHALL be trusted
- **AND** trust and rotation audit events SHALL include actor, target, agent, key type, fingerprint, and lifecycle decision.

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
- **THEN** the audit event SHALL include actor, target, selected agent, protocol, credential rule or custody mode, RBAC/approval result, timestamps, and terminal outcome
- **AND** the audit event SHALL NOT include plaintext credentials.

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
- **THEN** the system SHALL persist a recording manifest with storage pointer, retention expiry, lifecycle status, and aggregate input/output byte counters
- **AND** raw terminal byte contents SHALL NOT be persisted unless a separate explicit content-recording policy permits it.

### Requirement: Remote access file transfer is policy controlled
The system SHALL plan SFTP/SCP-style file transfer as a remote-access capability that inherits session identity, RBAC, approval, credential custody, recording, quota, and target routing gates.

#### Scenario: Browser cannot choose file-transfer policy
- **WHEN** the browser requests a file-transfer operation
- **THEN** the browser-facing API SHALL accept only bounded operation, direction, and path intent fields
- **AND** it SHALL reject client-supplied route, selected agent, target host, credential rule, custody, recording policy, content-audit policy, approval, or quota fields
- **AND** trusted remote-access policy SHALL select the final route, credential mode, recording behavior, and quota before target access starts.

#### Scenario: File transfer requires scoped RBAC and approval
- **GIVEN** an operator requests list, download, upload, or file-management access
- **WHEN** the operator lacks the required file-transfer permission or a required approval is missing, expired, or mismatched
- **THEN** the system SHALL deny the transfer before the selected agent opens a target file handle
- **AND** the denial SHALL be audited without exposing credentials or file contents.

#### Scenario: Path and quota policy are enforced before access
- **GIVEN** a file-transfer policy defines path rules, symlink behavior, byte limits, file-count limits, recursive-depth limits, or concurrent-transfer limits
- **WHEN** a transfer is requested
- **THEN** the selected agent SHALL enforce those policy gates before opening or mutating target files
- **AND** relative paths, symlinks, and realpaths SHALL be validated according to policy
- **AND** unclear or unverifiable paths SHALL fail closed.

#### Scenario: Content audit stores metadata by default
- **WHEN** a file transfer starts, progresses, completes, or fails
- **THEN** the system SHALL record transfer lifecycle metadata, byte counts, status, policy decision, and hashes when enabled
- **AND** file contents SHALL NOT be persisted in recordings, replay events, audit events, or exports unless an explicit content-audit policy enables a sensitive artifact retention path.

#### Scenario: SFTP is the first-class transfer model
- **WHEN** ServiceRadar adds file-transfer support
- **THEN** SFTP SHALL be the preferred first implementation because it exposes structured operations for policy, quota, and audit
- **AND** SCP compatibility SHALL NOT be added unless it maps to the same transfer manager, authorization checks, quota enforcement, recording events, and content-audit controls.

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

#### Scenario: Authentik smoke path proves enterprise certificate flow
- **GIVEN** the Kubernetes Authentik namespace is reachable
- **WHEN** the Authentik/OpenSSH smoke harness runs
- **THEN** it SHALL provision disposable Authentik OIDC fixtures, exchange an authorization code for a signed ID token, verify the token through ServiceRadar OIDC handling, map claims to an SSH principal, issue a short-lived ServiceRadar OpenSSH certificate, and authenticate to an OpenSSH target through `TrustedUserCAKeys`
- **AND** it SHALL clean up disposable fixtures by default
- **AND** it SHALL NOT persist target passwords, shared bastion credentials, reusable private keys, ID tokens, or certificate envelopes.

#### Scenario: Certificate issuance is denied before target dial
- **GIVEN** the requested principal, target, agent route, approval, MFA state, or TTL violates policy
- **WHEN** the operator attempts to open an SSH session
- **THEN** ServiceRadar SHALL deny certificate issuance before the selected agent dials the target
- **AND** the denial SHALL be audited without exposing credential material.

#### Scenario: SSH certificate request and signer response fields are bounded
- **WHEN** ServiceRadar authorizes or signs an SSH certificate request
- **THEN** session, agent, public-key, target, principal, and signer-response certificate fields SHALL be bounded before issuance succeeds
- **AND** oversized certificate request or signer response fields SHALL be rejected without invoking target access.

#### Scenario: Identity claim principal expansion is bounded
- **WHEN** ServiceRadar maps OIDC/SAML identity claims to SSH principals
- **THEN** mapping count, claim value count, individual claim value size, and selected principal count SHALL be bounded
- **AND** oversized claim values SHALL NOT produce SSH principals.

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

#### Scenario: Required BPF uses ServiceRadar-owned cilium runtime
- **GIVEN** a remote-access policy requires BPF enhanced recording
- **WHEN** the selected agent evaluates whether it can satisfy the policy
- **THEN** the agent SHALL use the shared ServiceRadar `go/pkg/agent/ebpf` runtime backed by `github.com/cilium/ebpf`
- **AND** it SHALL NOT use Teleport BPF implementation source unless the exact source path and transitive dependency path have been cleared for Apache-2.0 reuse.

#### Scenario: BPF loss counters are auditable
- **GIVEN** BPF enhanced recording is active
- **WHEN** kernel buffers, parser logic, or user-space backpressure drop events
- **THEN** the agent SHALL emit loss-counter events correlated to the remote-access session
- **AND** policy MAY later fail closed when loss exceeds a configured threshold.
