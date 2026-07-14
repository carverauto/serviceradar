# rbac-route-protection Specification

## Purpose
TBD - created by archiving change fix-rbac-route-protection-wildcard-fallback. Update Purpose after archive.
## Requirements
### Requirement: Route protection falls back from exact method maps to wildcard patterns
When `rbac.route_protection` contains both wildcard patterns (for example `/api/admin/*`) and an exact path entry for a concrete route, the core API MUST NOT bypass wildcard protections solely due to the presence of the exact path entry. If the exact path entry is a method-specific map and does not define roles for the requested HTTP method, the core API MUST continue evaluating wildcard patterns and apply any matching wildcard protection.

#### Scenario: Exact match missing method falls back to wildcard protection
- **GIVEN** `rbac.route_protection` includes `/api/admin/*: ["admin"]`
- **AND** `rbac.route_protection` includes an exact entry for `/api/admin/users` with method-specific roles that only define `POST: ["operator"]`
- **WHEN** a request is made to `GET /api/admin/users`
- **THEN** the required roles include `admin` (from the wildcard protection)

### Requirement: Method-specific exact matches override wildcard protection when defined
When an exact path entry defines roles for the requested HTTP method, those roles MUST be used in preference to roles from wildcard protections.

#### Scenario: Exact match method roles override wildcard roles
- **GIVEN** `rbac.route_protection` includes `/api/admin/*: ["admin"]`
- **AND** `rbac.route_protection` includes an exact entry for `/api/admin/users` with method-specific roles that define `POST: ["operator"]`
- **WHEN** a request is made to `POST /api/admin/users`
- **THEN** the required roles include `operator`
- **AND** the required roles do not fall back to `admin` for that request

### Requirement: RBAC includes regression tests for route protection resolution
The core RBAC implementation MUST include unit tests that cover precedence and fallback behavior between exact path entries and wildcard patterns in `rbac.route_protection`.

#### Scenario: Regression tests detect wildcard bypass
- **GIVEN** a test configuration that includes a wildcard protection and an exact method map that does not define the requested method
- **WHEN** the route protection resolution is exercised by tests
- **THEN** tests fail if required roles are empty when a matching wildcard protection exists

### Requirement: Remote access requires explicit authorization
Remote-access APIs, channels, and session attach paths SHALL require explicit RBAC permissions distinct from read-only device visibility.

#### Scenario: Device viewer cannot open shell
- **GIVEN** a user can view a device details page
- **AND** the user lacks remote-access permission
- **WHEN** the user attempts to create or attach to a remote-access session
- **THEN** the request SHALL be denied
- **AND** no session grant SHALL be issued.

### Requirement: Privileged remote access may require approval
Remote-access policy SHALL support approval requirements for sensitive targets, credential modes, or roles.

#### Scenario: Approval required for broad SSH credential
- **GIVEN** a credential rule is marked as requiring approval
- **WHEN** an operator requests a session using that credential rule
- **THEN** no session, attach ticket, or credential grant SHALL be issued until an authorized approver approves the separate access request
- **AND** the access request SHALL expire if not approved before its deadline.

### Requirement: Remote access authorization is rechecked on attach
The system SHALL recheck authorization when a browser attaches or reattaches to an existing remote-access session.

#### Scenario: Revoked user cannot reattach
- **GIVEN** a user opened a remote-access session
- **AND** the user's remote-access permission is revoked
- **WHEN** the user attempts to reattach after disconnecting
- **THEN** the attach request SHALL be denied
- **AND** the denial SHALL be audited.
