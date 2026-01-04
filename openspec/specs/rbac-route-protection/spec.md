# rbac-route-protection Specification

## Purpose
TBD - created by archiving change fix-rbac-route-protection-wildcard-fallback. Update Purpose after archive.
## Requirements
### Requirement: Route protection falls back from exact method maps to wildcard patterns
When `rbac.route_protection` contains both wildcard patterns (for example `/api/admin/*`) and an exact path entry for a concrete route, the core API MUST NOT bypass wildcard protections solely due to the presence of the exact path entry. If the exact path entry is a method-specific map and does not define roles for the requested HTTP method, the core API MUST continue evaluating wildcard patterns and apply any matching wildcard protection.

#### Scenario: Exact match missing method falls back to wildcard protection
- **GIVEN** `rbac.route_protection` includes `/api/admin/*: ["admin"]`
- **AND** `rbac.route_protection` includes an exact entry for `/api/admin/users` with method-specific roles that only define `POST: ["superadmin"]`
- **WHEN** a request is made to `GET /api/admin/users`
- **THEN** the required roles include `admin` (from the wildcard protection)

### Requirement: Method-specific exact matches override wildcard protection when defined
When an exact path entry defines roles for the requested HTTP method, those roles MUST be used in preference to roles from wildcard protections.

#### Scenario: Exact match method roles override wildcard roles
- **GIVEN** `rbac.route_protection` includes `/api/admin/*: ["admin"]`
- **AND** `rbac.route_protection` includes an exact entry for `/api/admin/users` with method-specific roles that define `POST: ["superadmin"]`
- **WHEN** a request is made to `POST /api/admin/users`
- **THEN** the required roles include `superadmin`
- **AND** the required roles do not fall back to `admin` for that request

### Requirement: RBAC includes regression tests for route protection resolution
The core RBAC implementation MUST include unit tests that cover precedence and fallback behavior between exact path entries and wildcard patterns in `rbac.route_protection`.

#### Scenario: Regression tests detect wildcard bypass
- **GIVEN** a test configuration that includes a wildcard protection and an exact method map that does not define the requested method
- **WHEN** the route protection resolution is exercised by tests
- **THEN** tests fail if required roles are empty when a matching wildcard protection exists

