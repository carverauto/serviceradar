## ADDED Requirements

### Requirement: Agent-ephemeral SSH uses an effective runtime capability
An agent SHALL advertise `remote_access.ssh.agent_ephemeral_key_v1` only when its
applied configuration enables the mode and its local key-generation, SSH client,
frame protocol, cleanup, and required helper/runtime self-tests are compatible
and healthy. Compile-time linking or an assignment alone MUST NOT advertise it.

#### Scenario: SSH code exists but applied policy disables it
- **WHEN** an agent binary includes SSH support but its applied feature set disables agent-ephemeral SSH
- **THEN** it omits the capability and rejects key-prepare frames

#### Scenario: Local self-test fails
- **WHEN** key generation, buffer cleanup, SSH runtime, or protocol self-test fails
- **THEN** the agent withdraws the capability, rejects new opens, and reports only a sanitized readiness reason

### Requirement: SSH handshake return frames preserve authenticated route ownership
Every key-ready, SSH-ready, error, and close frame SHALL be accepted only from
the authenticated agent/gateway route bound to the session. A return frame MUST
bind the one-use nonce, target digest, and deadline before it can trigger signing
or lifecycle mutation.

#### Scenario: Selected route returns the key-ready frame
- **WHEN** the bound agent returns a valid in-deadline public key and nonce on its authenticated stream
- **THEN** the control plane may request the target-bound certificate

#### Scenario: Another route guesses the session and nonce
- **WHEN** another agent or gateway returns a key-ready or ready frame for the session
- **THEN** the frame is rejected before signing, recording, broadcast, audit success, or session activation

