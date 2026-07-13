# Change: Enable agent-routed SSH with agent-generated keys

## Why

ServiceRadar's current SSH certificate mode still requires the browser to paste
and transmit a private key. The certificate is signed before the selected edge
route proves readiness, agents advertise SSH without an effective runtime
capability check, and device actions are exposed from an operating-system name
heuristic rather than registered target, route, trust, and signer readiness.

The approved secure-access program requires a Teleport-like custody model: the
selected edge agent creates a fresh per-session key only after attach, the
control plane signs only its public key for a target-specific principal, and no
private key enters the browser, web tier, control plane, gateway, audit, or
durable agent state.

## What Changes

- Add a route-first SSH key handshake with typed prepare, public-key-ready,
  certificate, ready, error, and close phases over the authenticated selected
  agent/gateway route.
- Generate a fresh Ed25519 key inside the selected agent's bounded per-session
  runtime after atomic attach-ticket consumption. Return only the public key and
  route-bound nonce; consume and wipe the private key on open, timeout, failure,
  route loss, revocation, or close.
- Move SSH certificate issuance after the authenticated agent public-key frame.
  Bind issuance and idempotent retry to actor, session, registered target, local
  account, opaque target principal, route, public key, policy version, signer/CA
  revision, and a short open-window expiry.
- Package and configure the existing ServiceRadar SSH CA signer as a secure-off
  deployment dependency. The CA private key remains only in the signer boundary;
  the control plane publishes only the public CA bundle used by approved
  enrollment automation.
- Add an effective capability
  `remote_access.ssh.agent_ephemeral_key_v1`. Advertise it only when applied
  configuration, signer policy, local SSH runtime, and key-generation self-test
  are compatible and healthy.
- Replace heuristic device eligibility with server-derived registered SSH
  target, selected live route, host-key trust, target enrollment, signer,
  capability, actor permission, and current proof readiness.
- Remove private/public key and passphrase fields from SSO certificate mode.
  **BREAKING**: browser/user-present key custody becomes a separately named,
  default-off transitional policy and is never an automatic fallback.
- Disable file transfer for agent-ephemeral sessions until it can reuse the
  authenticated terminal connection or obtain a separate bounded key instead of
  retaining terminal credentials for redial.
- Add deployed proofs for `192.168.2.22` and `192.168.1.62`, including host-key
  rotation, wrong-route frames, signing retry, route loss, expiry, cleanup, and
  private-key non-disclosure assertions.

## Impact

- Affected specs: `edge-architecture`, `agent-connectivity`, `device-inventory`
- Affected code: `go/pkg/agent/remoteaccess`, `go/pkg/agent`,
  `elixir/serviceradar_core/lib/serviceradar/edge`,
  `elixir/serviceradar_agent_gateway`, `elixir/web-ng`,
  `go/cmd/tools/sshca-signer`, Helm/demo configuration, and remote-access docs
- Operational impact: a ServiceRadar SSH user CA secret/public-key lifecycle,
  explicit Linux target enrollment and host-key approval, new readiness proofs,
  and a staged canary rollout before the SSH feature flag may be enabled

