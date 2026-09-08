## 1. Design And Data Model
- [ ] 1.1 Define registered database target resources for PostgreSQL, including route, TLS, credential, query policy, approval, and recording fields.
- [ ] 1.2 Define the database session lifecycle, typed frames, cancellation semantics, and route binding shared by web-ng, core, agent-gateway, and agent.
- [ ] 1.3 Define credential grant types for mTLS/client certificates, short-lived database passwords, database-native ephemeral tokens, and centrally brokered fallback secrets.
- [ ] 1.4 Record exact dependency choices for PostgreSQL parsing and driver support before implementation.

## 2. Policy, RBAC, And API
- [ ] 2.1 Add database target RBAC and approval checks that bind actor, target, route, policy snapshot, and credential grant to one session.
- [ ] 2.2 Add APIs for listing authorized database targets, creating sessions, executing worksheet queries, cancelling queries, and closing sessions.
- [ ] 2.3 Add query/result policy enforcement for read-only mode, denied statement classes, timeouts, max rows, max bytes, export restrictions, and parse-failure denial.
- [ ] 2.4 Add audit/recording metadata events with query redaction, query hashes, policy decisions, row/byte counts, timing, and error classification.

## 3. Agent Route And PostgreSQL Adapter
- [ ] 3.1 Add typed database frames to the agent-gateway route without reusing terminal byte frames blindly.
- [ ] 3.2 Implement the agent PostgreSQL adapter for registered targets only, including TLS verification and session-scoped credential use.
- [ ] 3.3 Ensure credentials and generated client keys remain memory-only and are dropped on session close, timeout, policy revocation, or route loss.
- [ ] 3.4 Add cancellation, cleanup, backpressure, and result quota behavior.

## 4. Operator And User Experience
- [ ] 4.1 Add web-ng target administration for PostgreSQL database targets and policy fields.
- [ ] 4.2 Add a browser SQL worksheet for authorized database sessions with visible target identity, credential mode, read-only status, quota state, and approval status.
- [ ] 4.3 Add recording/audit views for database session lifecycle and query metadata without result values by default.
- [ ] 4.4 Add operator docs for enrolling PostgreSQL targets, configuring TLS/client cert trust, Authentik-backed identity mapping, and session policy.

## 5. Validation And Demo
- [ ] 5.1 Add unit tests for resource normalization, override rejection, RBAC, approval, query classification, redaction, quotas, and audit records.
- [ ] 5.2 Add PostgreSQL integration tests for TLS, wrong CA failure, read-only enforcement, denied writes, cancellation, result caps, and cleanup.
- [ ] 5.3 Add route/session tests proving frames are accepted only on the selected route and terminate on revocation or route loss.
- [ ] 5.4 Add a demo proof path with a private PostgreSQL target reachable only from an agent.
- [ ] 5.5 Update the Teleport parity matrix after the PostgreSQL slice is implemented and validated.
