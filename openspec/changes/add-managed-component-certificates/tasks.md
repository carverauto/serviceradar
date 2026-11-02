## 1. Confirm existing boundaries and approve the design
- [x] 1.1 Trace CLI account readiness, leaf issuance, collector revoke, and agent renewal.
- [x] 1.2 Reconcile deferred #5257 work with existing renewal and hosted-leaf proposals.
- [ ] 1.3 Enumerate supported collector services and their certificate/reload interfaces.
- [ ] 1.4 Prove NATS leaf/client and Go/Rust/Erlang server-peer revocation mechanisms; record the chosen adapter and active-session termination method.
- [x] 1.5 Approve the design and online/offline enforcement contract before runtime changes.

## 2. Complete durable revocation and operator controls
- [ ] 2.1 Implement the existing CNPG revocation resource/migration contract through the canonical Ash workflow.
- [ ] 2.2 Reconcile all enforcement replicas at startup and after missed notifications.
- [ ] 2.3 Enforce revocation for NATS, agent-gateway, and core peers, including active sessions and renewal denial.
- [ ] 2.4 Add certificate inventory, scoped revoke/rotate/re-enroll actions, audit, and enforcement status.

## 3. Extend agent-managed identity lifecycle
- [ ] 3.1 Bind managed leaf and collector instances to enrolled host agents and authorize per-component CSRs.
- [ ] 3.2 Reuse renewal scheduling and atomic installation with registered service adapters.
- [ ] 3.3 Confirm successor use before predecessor retirement; preserve emergency revocation semantics.
- [ ] 3.4 Support adoption of existing installations without replacing unrelated identities.

## 4. Finish CLI onboarding and acceptance
- [ ] 4.1 Add authentication-mode-aware account readiness checks and actionable setup errors.
- [ ] 4.2 Route leaf and collector onboarding through the enrolled host agent without exporting CA or account signing keys.
- [ ] 4.3 Prove rotation and targeted revoke with an unaffected peer, restart/failover, and an offline host.
- [ ] 4.4 Validate the online enforcement bound and report offline stale state accurately.
- [ ] 4.5 Run focused and repository checks, no-mistakes review, and the authorized cluster e2e.
