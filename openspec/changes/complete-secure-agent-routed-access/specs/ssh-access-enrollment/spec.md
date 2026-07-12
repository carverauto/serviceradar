## ADDED Requirements

### Requirement: SSH targets trust only the public ServiceRadar user CA
The system SHALL enroll approved SSH targets by installing the public ServiceRadar user CA and validated sshd principal policy. The CA private key MUST remain in the control-plane signing boundary and MUST NOT be distributed to targets, browsers, gateways, or agents.

#### Scenario: Atomic target enrollment
- **WHEN** an operator enrolls an approved Linux target
- **THEN** automation installs the public CA, validates sshd configuration, reloads SSH atomically, verifies the mapped principal, and retains a rollback path

#### Scenario: Existing account policy is preserved
- **WHEN** certificate authentication is enabled for the `mfreeman` principal
- **THEN** the target's existing local account, PAM, LDAP, sudo, and session policy remain authoritative after certificate authentication

#### Scenario: ServiceRadar launches Ansible enrollment
- **WHEN** the authorized integrated workflow enrolls a target
- **THEN** ServiceRadar supplies a run-bound delegated callback grant to AWX, AWX retrieves the public CA/principal bundle once, and no private key, user access token, general API key, or callback token reaches the target

### Requirement: SSO SSH sessions use agent-generated target-bound keys and certificates
After authorization and atomic attach-ticket consumption, the selected agent SHALL generate a fresh Ed25519 keypair inside the per-session SSH runtime. It SHALL send only the public key, nonce, and authenticated actor/session/registered-target/local-account/agent/gateway/policy binding to the signer. The private key MUST NOT enter the browser, web-ng, core, gateway, audit, recording, logs, traces, or durable agent state.

The signer SHALL issue one short-lived certificate for an opaque target-specific principal authorized to the approved local account through `AuthorizedPrincipalsFile`. It SHALL permit only the required PTY extension, omit forwarding and user-rc extensions, use `source-address` when stable selected-route egress is registered, and limit validity to the attach/open authentication window. Target-specific principal binding remains mandatory even when `source-address` is used.

#### Scenario: SSO certificate session
- **WHEN** an authorized user opens SSH with SSO certificate custody
- **THEN** the selected agent creates the key after attach, the control plane signs only its public key for the target-specific principal and bounded TTL, and the certificate returns only over the authenticated selected route

#### Scenario: Signing is retried
- **WHEN** the selected agent repeats the signing request for the same session and public key after losing the response
- **THEN** the signer may return the same certificate idempotently, but rejects a different public key for that session

#### Scenario: Certificate is tried on another enrolled host
- **WHEN** a certificate issued for one target is presented to another host that trusts the same CA and has the same local account
- **THEN** authentication fails because the second host does not authorize the first target's opaque principal

#### Scenario: Session closes
- **WHEN** the SSH session closes, expires, is revoked, or loses its route
- **THEN** the agent drops its private-key object, serialized buffers, and certificate and no reusable target credential remains

#### Scenario: User-present key mode is not enabled
- **WHEN** agent-generated SSO custody is unavailable and user-present key custody is not explicitly allowed by policy
- **THEN** the session fails closed without falling back to a remembered, server, gateway, or reusable agent key

### Requirement: SSH readiness verifies route and host-key trust
The system SHALL mark a device SSH-ready only when a selected connected edge agent can reach the registered endpoint and the endpoint's host key is approved under the configured known-host policy.

#### Scenario: Host key changes
- **WHEN** the selected agent observes a host key that conflicts with approved trust state
- **THEN** the session fails closed, the target becomes trust-unready, and an authorized operator must review the rotation before access resumes

#### Scenario: Agent route is unavailable
- **WHEN** the device's selected agent is offline or cannot reach the registered SSH endpoint
- **THEN** the action reports route-offline or target-unreachable without falling back to a browser-selected agent or endpoint
