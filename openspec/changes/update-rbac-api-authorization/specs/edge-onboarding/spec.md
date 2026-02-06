## ADDED Requirements

### Requirement: Edge Onboarding Admin Operations Require RBAC Permission
Edge onboarding administrative operations (list, show, event listing, create, revoke, delete) MUST be restricted to actors with permission `settings.edge.manage` (or an equivalent dedicated permission key for edge onboarding management).

#### Scenario: Unauthorized user cannot access Edge onboarding admin UI
- **GIVEN** a logged-in user without `settings.edge.manage`
- **WHEN** the user visits `/admin/edge-packages`
- **THEN** the system denies access (redirect or error)

#### Scenario: Unauthorized token cannot access Edge onboarding admin API
- **GIVEN** an authenticated principal without `settings.edge.manage`
- **WHEN** the client calls `GET /api/admin/edge-packages`
- **THEN** the system returns `403 Forbidden`

### Requirement: Edge Package Delivery Remains Token-Gated
Token-gated delivery endpoints MUST validate the download token and MUST NOT rely on admin authentication for authorization. Token-gated delivery endpoints MUST NOT expose administrative list/read/mutate operations.

#### Scenario: Invalid download token is rejected
- **GIVEN** a package delivery endpoint is called with an invalid download token
- **WHEN** the request is processed
- **THEN** the system returns `401 Unauthorized` (or an equivalent error)

