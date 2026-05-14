# Change: Add remote access database adapters

## Why
ServiceRadar remote access now covers SSH/SFTP-style operational workflows, and application/TCP access is proposed separately. Operators also need controlled database sessions to private PostgreSQL and MySQL targets that are reachable only from edge agents.

Naive database proxying would create unacceptable risk: broad shared credentials, query/result exfiltration, destructive statements, query logs containing secrets, protocol downgrade, and long-lived pooled connections that outlive policy changes.

## What Changes
- Add registered database access targets routed through selected ServiceRadar agents.
- Start with PostgreSQL; add MySQL only after the same policy, credential-custody, audit, and demo model is proven.
- Prefer short-lived database credentials, mTLS client certificates, or database-native ephemeral authentication. Allow centrally brokered static database secrets only as session-scoped fallback grants when unavoidable.
- Add database-specific RBAC, approval, TLS policy, read-only/query policy, result and byte quotas, session timeout, query audit redaction, and recording/export controls.
- Keep current Teleport database proxy code as reference only because the current `lib/srv/db` dependency graph has AGPL transitive paths.

## Impact
- Affected specs: `edge-architecture`
- Affected code: web-ng database access UI/API, core remote-access target/session/policy/audit resources, agent-gateway routing, Go agent database adapters, RBAC catalog, demo manifests and fixtures.
