## ADDED Requirements

### Requirement: API Authentication Enforces Guardian Token Type
API authentication middleware MUST only accept Guardian JWTs intended for API use (token types `access` and `api`). Tokens issued for other flows (for example password reset tokens `reset` and refresh tokens `refresh`) MUST be rejected for API authentication.

#### Scenario: Password reset token is rejected by API auth
- **GIVEN** a valid Guardian token issued for password reset with `typ=reset`
- **WHEN** the client calls `GET /api/admin/edge-packages` with `Authorization: Bearer <token>`
- **THEN** the request is rejected with `401 Unauthorized`
- **AND** the request is not treated as an authenticated principal

#### Scenario: Access token is accepted by API auth
- **GIVEN** a valid Guardian token issued for a logged-in user with `typ=access`
- **WHEN** the client calls an API endpoint protected by API auth
- **THEN** the request is authenticated as that user

### Requirement: Admin APIs Require a Principal (No Nil-User Authentication)
Admin API endpoints MUST require an authenticated principal (user or service account). Authentication modes that produce a nil user context MUST NOT be treated as authenticated for admin operations.

#### Scenario: Legacy key producing nil user cannot access admin API
- **GIVEN** an API authentication mode that results in `current_scope.user = nil`
- **WHEN** the client calls `POST /api/admin/collectors`
- **THEN** the request is rejected with `401 Unauthorized` (or `403 Forbidden`)
- **AND** no admin operations are executed

