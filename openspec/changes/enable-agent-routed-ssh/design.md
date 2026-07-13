## Context

The delivered SSH flow creates a durable session and single-use attach ticket,
then accepts browser-supplied private/public keys in the first WebSocket attach
message. Certificate mode signs that browser public key before the broker has
contacted the selected agent. The private key then crosses web-ng, core broker,
gateway, and agent frames and is retained by the agent for file-transfer redial.

The existing control stream already authenticates agent/gateway ownership for
console return frames, and the existing signer boundary already accepts only a
public key, principals, certificate ID, and TTL. The new flow keeps those useful
boundaries while changing key custody and handshake ordering.

## Goals / Non-Goals

### Goals

- Keep the per-session SSH private key exclusively inside the selected agent.
- Prove the selected route before signing and bind every phase to immutable
  session, target, actor-policy, route, and expiry state.
- Use target-specific opaque principals so a certificate cannot authenticate to
  another enrolled host that trusts the same CA.
- Make retries and cleanup deterministic without enabling browser-key fallback.
- Expose SSH only from authoritative live readiness.

### Non-Goals

- Do not introduce a ServiceRadar PAM module, shared bastion key, target agent,
  or reusable credential on Linux hosts.
- Do not send the CA private key to ServiceRadar agents, gateways, browsers, or
  enrollment jobs.
- Do not enable agent-ephemeral SFTP by retaining or reusing the terminal key.
- Do not silently migrate user-present keys into the new custody mode.

## Decisions

### Decision: Attach selects the route before key generation

The browser creates a server-derived SSH session and attaches with its one-use
ticket but no credential material. Atomic ticket consumption freezes the
registered target, local account, selected agent/gateway, actor, host-key policy,
and signer policy. The broker sends `ssh_key_prepare` with a random nonce and
short deadline to that route. It does not dial the target yet.

The selected agent validates the frame binding, allocates bounded pending state,
generates Ed25519 key material, and returns `ssh_key_ready` containing only the
public key, nonce, session, target digest, and deadline. A wrong-route, duplicate,
late, oversized, or mismatched frame is rejected before signing.

### Decision: The control plane owns signing policy; the agent proves key custody

The authenticated `ssh_key_ready` frame supplies only the public key. The
control plane combines it with the already authorized actor, session, registered
target, local account, opaque target-specific principal, route, policy version,
and CA revision. The agent cannot select principals, account, host, route, TTL,
or certificate options.

The signer allows one logical certificate per session/public-key/policy
partition. A retry for the same public key may return the same certificate;
another public key, route, target, account, principal, or policy is denied. The
certificate permits only PTY/session use, omits forwarding and user-rc
extensions, and uses a short validity covering only open authentication.
`source-address` is added only when the registered selected-route egress is
stable and part of policy; it never replaces target-specific principals.

### Decision: The agent consumes and wipes key material after SSH opens

The certificate frame returns only over the authenticated owning route. The
agent verifies that it certifies the pending public key and expected principal,
then dials the registered endpoint with approved host-key verification. Once the
SSH client is established, it removes pending state and overwrites mutable
private-key and serialized buffers before releasing them. The same cleanup runs
on every error, timeout, duplicate, close, route loss, and revocation path.

The existing file-transfer implementation redials from retained SSH config, so
file transfer is unavailable for this custody mode. A future change may reuse an
already authenticated connection or issue a distinct bounded transfer key.

### Decision: Browser-key custody is transitional and separately gated

SSO certificate mode never renders, stores, or sends a private key, public key,
or passphrase. The server rejects those fields for agent-ephemeral sessions. Any
remaining `user_present` mode requires an explicit default-off deployment and
policy gate, is labeled as user-custodied, and is never selected as fallback.
Disabling it removes all remembered remote-access key entries by prefix rather
than only the currently viewed device.

### Decision: Readiness is an intersection, not a feature flag

The master SSH flag is necessary but insufficient. A device action additionally
requires one current registered target, selected connected route, applied
`remote_access.ssh.agent_ephemeral_key_v1` capability, healthy signer and CA
policy, fresh target reachability proof, approved host key, enrolled target CA
policy version, permitted local-account mapping, actor permission, and no active
hold. Session creation re-evaluates readiness atomically.

## Risks / Trade-offs

- The multi-phase handshake adds latency and state. Deadlines, one-use nonces,
  bounded pending maps, and terminal reaping keep it finite.
- Go cannot guarantee compiler-proof zeroization of every library copy. The
  implementation uses mutable byte-backed keys, minimizes copies and lifetime,
  overwrites owned buffers, clears references, and verifies non-disclosure at
  every observable boundary.
- Route loss after signing may leave a still-valid certificate for seconds, but
  the private key remains only on the lost agent and is destroyed by route/session
  cleanup. Very short validity and target-specific principals bound impact.
- Disabling file transfer reduces initial parity but avoids retaining terminal
  credentials in a long-lived map.

## Migration Plan

1. Land protocol/state/capability code secure-off and keep current SSH disabled.
2. Package the signer and create the public CA policy without exposing its key.
3. Enroll and approve host keys for two canaries through the reviewed Ansible
   workflow.
4. Pass browser-to-agent-to-target and denial/non-disclosure proofs.
5. Enable agent-ephemeral SSH for only the canary targets, then expand bounded
   partitions. Keep user-present custody disabled unless separately approved.

Rollback disables agent-ephemeral readiness, closes active sessions, wipes
pending agent keys, revokes signing use, and leaves the public CA trust on targets
for a separately reviewed overlap/removal workflow. It never re-enables browser
key fallback automatically.

