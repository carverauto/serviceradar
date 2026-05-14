## Context
Teleport-style database access gives users a controlled way to reach private databases after SSO/RBAC checks. ServiceRadar should provide the same enterprise posture while fitting the existing agent-routed remote-access model:

```text
browser SQL worksheet or future short-lived client connector
  -> web-ng database access endpoint
  -> core policy/session/recording manager
  -> agent-gateway selected route
  -> existing agent-initiated control stream
  -> agent database adapter
  -> registered private database upstream
```

The database adapter must never accept browser-supplied upstream hosts, ports, database names, database users, TLS policy, credential references, agent routes, or recording settings. Those values must come from trusted ServiceRadar inventory and policy resources.

## Goals
- Provide controlled access to registered private PostgreSQL targets through an edge agent.
- Preserve one actor, one access session, one selected agent/gateway route, one database target, one credential grant, one policy snapshot, and one audit/recording boundary.
- Prefer short-lived database identity: generated database passwords, database-native ephemeral tokens, or mTLS client certificates where available.
- Keep database credentials out of browser storage and persisted session metadata.
- Enforce database-specific query, result, byte, timeout, approval, and recording policy before and during execution.
- Record query/session metadata by default without storing result values unless a future explicit content-retention policy enables it.
- Keep implementation ServiceRadar-owned unless a future exact-file Teleport vendoring review approves a small Apache-compatible utility.

## Non-Goals
- Do not provide arbitrary database tunnels to client-supplied hosts.
- Do not implement write/admin database access in the first implementation slice.
- Do not pool database connections across remote-access sessions.
- Do not store database passwords, generated client private keys, query result values, or raw unredacted query text by default.
- Do not implement Kubernetes, RDP, or generic TCP behavior in this proposal.
- Do not copy current Teleport `lib/srv/db` implementation code.

## First Slice
The first implementation should be a browser SQL worksheet for registered PostgreSQL targets. This is narrower and safer than exposing native PostgreSQL protocol forwarding immediately:

1. User selects a registered database target.
2. web-ng asks core to create a database access session.
3. core resolves RBAC, approval, route, TLS, credential mode, query policy, result policy, recording policy, and retention policy from trusted resources.
4. agent-gateway opens a typed database session over the selected agent route.
5. The agent database adapter connects to the registered upstream using a session-scoped credential grant.
6. Each worksheet query is classified, executed under read-only and timeout controls, capped by result and byte quotas, and recorded as metadata.

A later native-client connector can reuse the same target, route, credential, policy, and recording model. It should use a short-lived local listener or token and still prohibit arbitrary target changes.

## Resource Model
The first implementation should introduce a registered database target resource, or extend the remote-access target model, with:

- stable target ID
- display name and inventory/device relation
- engine: `postgres` first, `mysql` later
- selected agent or allowed agent set
- upstream host/IP, port, and database or service name from trusted inventory/policy
- upstream TLS mode, CA bundle reference, SNI/server name, and client certificate reference where applicable
- authentication mode: short-lived password, mTLS/client certificate, database-native ephemeral token, or centrally brokered session grant
- allowed database principals and role mapping from ServiceRadar actor/traits
- read-only required flag
- statement policy: allowed statement classes, denied statement classes, max rows, max bytes, statement timeout, lock timeout, idle timeout, export policy, and explain policy
- redaction policy for query text, parameters, errors, and database object names
- approval, recording, retention, and export policy

## Credential Custody
Database credentials must not be stored in the browser or accepted from the browser request.

Preferred credential modes:

- PostgreSQL mTLS client certificates mapped to database roles.
- Generated short-lived database passwords or roles when ServiceRadar can safely create and revoke them.
- Cloud or database-native ephemeral tokens in a later provider-specific slice.

Fallback mode:

- A central static database secret may be held only in the existing secret-management path and issued to an agent as a session-scoped grant with TTL, target binding, actor binding, route binding, and audit metadata. This is a compatibility escape hatch, not the default enterprise posture.

The agent should not persist granted database passwords or generated client keys to disk. Any retry must return to core for a still-valid session grant.

## Query And Result Policy
The first PostgreSQL slice should fail closed when a statement cannot be safely classified.

Controls:

- run sessions in explicit read-only transactions
- set `statement_timeout`, `lock_timeout`, and idle timeout
- deny DML, DDL, privilege changes, session setting changes that weaken policy, file access functions, large-object export, `COPY TO STDOUT`, and extension-backed network/file functions unless a future explicit policy allows them
- enforce max rows and max response bytes per query
- redact literal values and sensitive comments before recording query text
- record query hash and normalized redacted query text, not raw query text by default

The implementation should use a PostgreSQL-aware parser or conservative classifier. If parsing support is not available for a statement, the policy result is denial.

## Recording And Audit
Database access recording stores metadata by default:

- actor, session, route, target, engine, database principal, and credential mode
- normalized redacted query text and query hash
- statement class and policy decision
- start/end timestamps, duration, rows, bytes, status, error class, and cancellation reason
- approval and reviewer metadata when required

Result values are sensitive data and must not be persisted by default. Any future result-content recording requires separate approval, explicit retention policy, RBAC, and export controls.

## Source Reuse
Current Teleport database access code is not approved for import:

```bash
TELEPORT_SRC=$HOME/src/teleport scripts/check-teleport-license-paths.sh \
  github.com/gravitational/teleport/lib/srv/db \
  github.com/gravitational/teleport/lib/srv/db/postgres \
  github.com/gravitational/teleport/lib/srv/db/mysql
```

The current checkout reports AGPL transitive dependencies through Teleport API/types/auth/logging/proto paths. Treat Teleport behavior as product and architecture reference only. Use ServiceRadar-owned code plus Go database drivers or small Apache-compatible dependencies after explicit dependency review.

## Validation
- Unit tests for database target/resource normalization rejecting client-selected upstreams, database names, users, TLS modes, credential references, routes, quotas, and recording overrides.
- RBAC and approval tests proving access is denied without target permission and approval where required.
- Policy tests for allowed read-only statements, denied DML/DDL, denied exports, tricky comments/CTEs, parse failures, quotas, and timeouts.
- Agent adapter tests with local PostgreSQL proving TLS verification, wrong-CA failure, result caps, cancellation, session cleanup, and credential non-persistence.
- Channel/route tests proving frames are accepted only over the selected session route.
- Audit/recording tests proving metadata is recorded and result values are not retained by default.
- Demo proof with a private PostgreSQL target reachable only from an agent, ideally using Authentik-backed user identity and a ServiceRadar-issued session grant.
