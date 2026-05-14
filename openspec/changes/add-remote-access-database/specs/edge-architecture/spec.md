## ADDED Requirements
### Requirement: Registered database access targets
ServiceRadar SHALL provide remote database access only to registered database targets selected by trusted inventory or policy, not by browser-supplied upstream addresses or database connection settings.

#### Scenario: User opens a registered PostgreSQL target
- **GIVEN** an authenticated user is authorized to open a registered PostgreSQL database target
- **AND** the target has a selected agent route and trusted upstream policy
- **WHEN** the user starts a database access session
- **THEN** ServiceRadar SHALL derive the upstream host, port, database name, database principal, TLS policy, credential mode, query policy, quotas, approval requirement, and recording policy from trusted target state
- **AND** SHALL route the session through the selected agent.

#### Scenario: Client cannot select an arbitrary database upstream
- **GIVEN** a browser or API client requests database access
- **WHEN** the request includes an upstream host, port, database name, database user, route, gateway, agent, TLS verification override, credential reference, quota, approval override, or recording override
- **THEN** ServiceRadar SHALL reject the request before dispatching any agent frame.

### Requirement: Database credentials are short-lived and session-scoped
ServiceRadar SHALL keep database credentials out of browser storage and SHALL issue any database credential material to agents only as a session-scoped, target-bound grant.

#### Scenario: Session uses short-lived database identity
- **GIVEN** a database target supports mTLS client certificates, generated short-lived passwords, or database-native ephemeral tokens
- **WHEN** ServiceRadar creates a database access session
- **THEN** ServiceRadar SHALL issue credential material only for the authorized actor, target, route, and session
- **AND** SHALL set an expiration no longer than the session policy allows
- **AND** SHALL avoid persisting the credential material in session metadata.

#### Scenario: Static secret fallback is tightly bound
- **GIVEN** a database target requires a centrally stored static database credential
- **WHEN** ServiceRadar grants database access for a session
- **THEN** ServiceRadar SHALL deliver the credential to the selected agent only as a target-bound, actor-bound, route-bound, TTL-bound session grant
- **AND** the agent SHALL keep it memory-only and drop it on session close, timeout, revocation, or route loss.

### Requirement: Database query and result policy is enforced
ServiceRadar SHALL enforce database-specific query policy, read-only controls, timeouts, and result limits before and during query execution.

#### Scenario: Read-only query is allowed within policy
- **GIVEN** a PostgreSQL database target requires read-only access
- **AND** the user is authorized for the target
- **WHEN** the user executes a query that the policy classifies as allowed read-only SQL
- **THEN** ServiceRadar SHALL execute it under read-only transaction controls
- **AND** SHALL enforce statement timeout, lock timeout, max rows, and max response bytes.

#### Scenario: Destructive or unclassified statement is denied
- **GIVEN** a PostgreSQL database target requires read-only access
- **WHEN** the user submits DML, DDL, privilege changes, export behavior, file access behavior, or SQL that cannot be safely classified
- **THEN** ServiceRadar SHALL deny the statement before execution
- **AND** SHALL record the denied policy decision.

### Requirement: Database sessions are route-bound and revocable
ServiceRadar SHALL bind every database access session to one selected route and SHALL terminate query execution when the route, policy, approval, or session is revoked.

#### Scenario: Route loss terminates database session
- **GIVEN** a database access session is active through a selected agent route
- **WHEN** the selected route is lost or the session is revoked
- **THEN** ServiceRadar SHALL cancel in-flight queries where possible
- **AND** SHALL close the upstream database connection
- **AND** SHALL record the termination reason.

#### Scenario: Client cannot change database route or target after creation
- **GIVEN** a database access session is active
- **WHEN** the client attempts to change the target, upstream connection settings, selected route, credential mode, query policy, quota, or recording policy
- **THEN** ServiceRadar SHALL reject the request or close the session.

### Requirement: Database recording stores metadata by default
ServiceRadar SHALL record database session lifecycle, credential mode, query metadata, policy decisions, byte counts, row counts, timing, and failures without storing result values by default.

#### Scenario: Query event is recorded without result content
- **GIVEN** a user executes a database query through ServiceRadar
- **WHEN** ServiceRadar writes audit or replay events
- **THEN** the event SHALL include actor, target, session, route, engine, database principal, credential mode, normalized redacted query text, query hash, statement class, policy decision, row count, byte count, status, and timing metadata
- **AND** SHALL NOT include query result values, raw unredacted query text, database passwords, or generated client private keys unless a future explicit content-retention policy enables result capture.
