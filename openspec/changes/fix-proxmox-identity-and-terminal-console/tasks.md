## 1. Provider instance identity

- [ ] 1.1 Add an immutable registered Proxmox `provider_instance_ref` and carry it through trusted assignments, collector envelopes, enrichment status, and console policy without deriving it from mutable display names.
- [ ] 1.2 Emit instance-scoped references for clusters, hosts, guests, datastores, disks, NICs, storage resources, and console targets; reject missing, unknown, disabled, or assignment-mismatched instances.
- [ ] 1.3 Add scoped uniqueness and relationship constraints that keep same-name Farm/Tonka nodes and overlapping guest identifiers independent.
- [ ] 1.4 Add a read-only legacy classifier/collision report using trusted assignment and source evidence; do not use display name, node, VMID, hostname, or IP alone.
- [ ] 1.5 Transactionally migrate uniquely proven rows and dependents, quarantine ambiguous/conflicting rows, re-ingest affected provider instances, and only then enforce non-null scoped identity.
- [ ] 1.6 Restrict legacy aliases to unique inventory compatibility inside one provider instance and forbid them as console routing or authorization keys.
- [ ] 1.7 Add migration rollback, idempotency, relationship-count, and same-name Farm/Tonka regression tests.

## 2. Parent PVE terminal target resolution

- [ ] 2.1 Replace first-row and metadata heuristic selection with exact scoped host/guest lookups that fail on zero, multiple, cross-instance, or quarantined results.
- [ ] 2.2 Resolve a guest to exactly one active parent PVE, registered endpoint/TLS policy, resource type/VMID, and parent-eligible agent/gateway/partition route while retaining the guest as display/audit target.
- [ ] 2.3 Add narrow server-derived target contracts for PVE node termproxy, LXC termproxy, and explicit QEMU serial termproxy paths; reject arbitrary endpoint, path, redirect, node, VMID, or mode overrides.
- [ ] 2.4 Require authoritative current serial-console registration for QEMU terminal readiness and return typed unavailable results for graphical-only, unknown, or stale QEMU configurations.
- [ ] 2.5 Remove `proxmox_vncwebsocket`, `vncproxy`, RFB, and graphical rendering from this terminal action and adapter; do not forward graphical bytes to xterm.

## 3. Console-purpose credentials

- [ ] 3.1 Require a distinct enabled `console_access` credential rule with provider instance, resource, endpoint, route, operation, privilege, and TTL scope.
- [ ] 3.2 Remove `inventory_enrichment` and `generic` purpose fallback and reject browser-supplied credential rule, provider, endpoint, route, TLS, node, VMID, or mode selection.
- [ ] 3.3 Resolve exactly one rule server-side, fail closed on conflict or scope mismatch, and validate least-privilege PVE node/guest console permissions.
- [ ] 3.4 Issue a one-session grant only after atomic attach, bind redemption to the selected agent/gateway and exact target/API allowlist, and keep decrypted material out of assignments and command persistence.
- [ ] 3.5 Add tests proving inventory-only discovery continues while terminal access is unavailable and that cross-instance, overbroad, wrong-route, conflicting, disabled, and expired rules cannot qualify.

## 4. Generic broker and agent adapter

- [ ] 4.1 Translate new Proxmox terminal opens into the generic `RemoteAccessSession` and broker with protocol `proxmox_console` and a typed PTY transport.
- [ ] 4.2 Freeze display target, parent PVE, provider instance, endpoint/TLS, route, credential rule, terminal mode, target digest, and policy revisions at create/attach.
- [ ] 4.3 Implement the bounded agent adapter for PVE/LXC/explicit QEMU serial termproxy setup, websocket I/O, input, resize, error, and close frames.
- [ ] 4.4 Apply atomic attach, create/attach and periodic authorization, authenticated route ownership, integrity/replay protection, recording policy, rate/size limits, idle/absolute timeouts, revocation, route-loss closure, and orphan reaping.
- [ ] 4.5 Keep any legacy provider-session compatibility facade read/close-only during a bounded drain; prevent new legacy opens and terminalize stale requested/active rows.
- [ ] 4.6 Add wrong-route, stale-generation, replay, duplicate, late, integrity failure, RBAC revoke, route loss, adapter error, timeout, agent restart, and reaper tests.

## 5. Readiness and device actions

- [ ] 5.1 Add secure-off deployment/provider policy and effective `remote_access.proxmox.terminal_v1` capability advertisement after applied configuration and local adapter/TLS/frame/cleanup self-tests pass.
- [ ] 5.2 Compute server-side readiness from scoped identity, parent relationship, terminal evidence, PVE endpoint/TLS trust, connected parent route, applied capability, one console rule, privilege, actor permission, approval/hold, adapter/renderer, and fresh proof.
- [ ] 5.3 Re-evaluate mutable readiness at create and attach and expose only sanitized typed unavailable reasons to authorized operators.
- [ ] 5.4 Add device-detail actions for ready PVE and LXC terminals and only explicitly registered QEMU serial terminals; do not expose graphical QEMU or RDP actions from this child.
- [ ] 5.5 Add API and UI tests proving browser fields cannot retarget, unavailable actions do not partially launch, and raw RFB/VNC is never rendered in xterm.

## 6. Credential lifecycle, audit, and cleanup

- [ ] 6.1 Redeem provider credentials only inside the bounded selected-agent runtime after attach and minimize/copy-bound mutable token, ticket, cookie, CSRF, proxy-ticket, and password state.
- [ ] 6.2 Close the provider websocket, revoke the grant, clear owned secret buffers/references and pending state, close browser transport, and record exactly one terminal outcome on every success and failure path.
- [ ] 6.3 Redact provider secrets and internal response bodies from URLs, logs, audit, recording, traces, support artifacts, terminal metadata, and public errors.
- [ ] 6.4 Audit actor, display target, parent PVE, provider instance, route, mode, policy revisions, time, and close reason without terminal content or credentials.
- [ ] 6.5 Add observable-boundary non-disclosure and cleanup assertions for normal close, setup failure, denial, expiry, replay, route loss, restart, and reaper paths.

## 7. Migration proof and rollout

- [ ] 7.1 Run the migration dry-run and review all collision/quarantine mappings before applying any data mutation in an approved environment.
- [ ] 7.2 Prove same-name Farm/Tonka nodes and overlapping guest identifiers retain distinct scoped records, parents, targets, credentials, and routes after migration/re-ingestion.
- [ ] 7.3 Pass an approved browser-to-parent-agent-to-PVE terminal proof for one PVE host and one LXC guest in each available provider instance, including cross-instance and wrong-parent denial cases.
- [ ] 7.4 Pass an approved QEMU serial termproxy proof only on a fixture with authoritative serial configuration; prove graphical-only QEMU remains unavailable and no RFB/VNC or RDP path is exercised.
- [ ] 7.5 Verify attach replay, credential fallback denial, authorization revocation, route loss, idle/absolute timeout, cleanup, redaction, audit, recording policy, and orphan reaping in the deployed path.
- [ ] 7.6 Enable only bounded canary resources after all identity and terminal proof gates pass; document expansion, observability, rollback, and legacy compatibility removal evidence.
