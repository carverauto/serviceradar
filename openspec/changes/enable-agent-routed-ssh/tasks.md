## 1. Protocol and custody

- [ ] 1.1 Add `ssh_key_prepare`, `ssh_key_ready`, `ssh_certificate`, and bounded terminal error/close frame contracts with authenticated route ownership.
- [ ] 1.2 Add agent pending-key state bound to session, registered target digest, agent/gateway route, nonce, policy, and expiry with strict size/count limits.
- [ ] 1.3 Generate Ed25519 keys only after prepare; return only the public key and wipe private/serialized buffers on every success and terminal path.
- [ ] 1.4 Verify the returned certificate matches the pending public key and expected principal before target dial; consume pending state exactly once.
- [ ] 1.5 Disable file transfer for agent-ephemeral sessions and reject any redial path that would retain the terminal key.

## 2. Signing and policy

- [ ] 2.1 Package the existing SSH CA signer into the required runtime image and add secure-off Helm/demo signer configuration and secret mounts.
- [ ] 2.2 Add target-specific opaque-principal policy and restrictive certificate extensions/options with bounded open-window TTL.
- [ ] 2.3 Add durable idempotent session/public-key signing state and deny substituted keys, routes, targets, accounts, principals, policies, or CA revisions.
- [ ] 2.4 Expose only the versioned public CA bundle/policy required by approved enrollment automation; keep the private key inside the signer boundary.

## 3. Readiness and lifecycle

- [ ] 3.1 Add default-off agent-ephemeral and user-present deployment/policy gates with no downgrade or fallback.
- [ ] 3.2 Advertise `remote_access.ssh.agent_ephemeral_key_v1` only after applied config and local runtime/key-generation self-test succeed.
- [ ] 3.3 Add registered SSH target, selected route, target probe, approved host-key, enrollment-policy, signer, actor, and hold readiness evaluation.
- [ ] 3.4 Re-evaluate readiness at create and attach; add key-preparing/certificate-pending/open deadlines, route-loss closure, reapers, and typed redacted failures.
- [ ] 3.5 Ensure wrong-route frames cannot sign, mutate, record, broadcast, or activate a session.

## 4. Browser and API

- [ ] 4.1 Remove key/passphrase collection, upload, localStorage, and attach payloads from SSO certificate mode.
- [ ] 4.2 Reject browser credential material for agent-ephemeral sessions and keep explicitly user-present custody behind its separate server gate.
- [ ] 4.3 Replace OS-name device eligibility with authoritative readiness and show sanitized unavailable reasons to authorized operators.
- [ ] 4.4 Clear all legacy remembered remote-access key entries by prefix when transitional custody is disabled.

## 5. Verification and rollout

- [ ] 5.1 Add Go tests for generation timing, public-only return, certificate match, replay/substitution, limits, timeout, route loss, and cleanup/zeroization.
- [ ] 5.2 Add Elixir/gateway tests proving signing follows authenticated key-ready, route ownership is enforced, tickets are atomic, and all failures become terminal.
- [ ] 5.3 Add React tests proving certificate mode never renders, stores, or transmits key/passphrase material and clears transitional state.
- [ ] 5.4 Add private-key non-disclosure assertions across browser frames, web/core state, command rows, gateway logs, audit, recording, traces, and support surfaces.
- [ ] 5.5 Enroll, approve host keys, and pass live SSH canaries for `192.168.2.22` and `192.168.1.62`, including denial and route-loss cases.
- [ ] 5.6 Enable only canary readiness, observe cleanup/audit, then document bounded fleet rollout and rollback evidence.

