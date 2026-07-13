## ADDED Requirements

### Requirement: SSO SSH private keys remain on the selected agent
After atomic attach-ticket consumption, the selected edge agent SHALL generate a
fresh Ed25519 keypair inside one bounded SSH session runtime. The private key
MUST NOT enter the browser, web-ng, core, gateway, audit, recording, logs,
traces, support artifacts, command persistence, or durable agent state.

#### Scenario: Agent-ephemeral SSO session opens
- **WHEN** an authorized user attaches to a ready registered SSH target in SSO certificate mode
- **THEN** the selected agent generates the key after attach and returns only its public key over the authenticated owning route
- **AND** the browser supplies and receives no private key, public key, or passphrase

#### Scenario: Session terminates during the key handshake
- **WHEN** signing, target open, timeout, revocation, route loss, duplicate use, or close terminates the session
- **THEN** the selected agent removes pending state, overwrites its owned mutable private-key buffers, clears references, and retains no reusable target credential

### Requirement: SSH certificate issuance follows route-bound key proof
The platform SHALL sign an agent public key only after accepting an authenticated
key-ready frame from the session's selected agent/gateway route. Issuance SHALL
bind actor, session, registered target, local account, target-specific opaque
principal, agent, gateway, nonce, public key, policy and CA revisions, and a
bounded open-window expiry. Request fields MUST NOT select or broaden those
values.

#### Scenario: Same public key retries after a lost response
- **WHEN** the owning agent repeats the same session, nonce, public key, route, and policy request within the open deadline
- **THEN** the signer may return the same certificate idempotently without creating broader authority

#### Scenario: Public key is substituted
- **WHEN** a retry changes the public key, target, account, principal, route, policy, or CA revision
- **THEN** issuance fails closed and the session cannot fall back to another credential mode

### Requirement: Agent-ephemeral SSH does not retain terminal credentials for file transfer
File transfer SHALL remain unavailable for an agent-ephemeral terminal session
until it can reuse the authenticated SSH connection or obtain a separately
authorized bounded transfer credential without retaining the terminal private
key or SSH configuration for redial.

#### Scenario: Browser requests SFTP on an ephemeral terminal
- **WHEN** an attached agent-ephemeral SSH session requests file transfer
- **THEN** the platform returns a typed unavailable result and does not retain, reconstruct, or mint a reusable terminal key

### Requirement: User-present SSH custody is explicit and never a fallback
Browser/user-present SSH key custody SHALL require a separate default-off
deployment and target policy. SSO agent-ephemeral failure MUST NOT downgrade to
user-present, remembered, gateway, server, or reusable agent keys.

#### Scenario: Agent-ephemeral capability is unavailable
- **WHEN** the selected route lacks the agent-ephemeral capability and user-present custody is not explicitly enabled
- **THEN** the action remains unavailable rather than asking the browser for a key

