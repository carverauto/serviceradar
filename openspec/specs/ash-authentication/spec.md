# ash-authentication Specification

## Purpose
TBD - created by archiving change integrate-ash-framework. Update Purpose after archive.
## Requirements
### Requirement: Magic Link Email Authentication
The system SHALL support passwordless authentication via magic link emails using AshAuthentication.

#### Scenario: Magic link login flow
- **GIVEN** a registered user with email user@example.com
- **WHEN** the user requests a magic link login
- **THEN** the system SHALL send an email with a single-use authentication link
- **AND** clicking the link SHALL authenticate the user and create a session

#### Scenario: Magic link expiration
- **GIVEN** a magic link token older than 15 minutes
- **WHEN** the user attempts to use the link
- **THEN** the system SHALL reject the authentication attempt
- **AND** display an appropriate error message

### Requirement: Password Authentication
The system SHALL support password-based authentication with secure hashing using AshAuthentication.

#### Scenario: Password login
- **GIVEN** a user with a registered password
- **WHEN** the user submits valid credentials
- **THEN** the system SHALL authenticate the user
- **AND** create a session token

#### Scenario: Password requirements
- **WHEN** a user sets or changes their password
- **THEN** the password MUST be at least 12 characters
- **AND** the password MUST be at most 72 bytes (bcrypt limit)

### Requirement: OAuth2 Authentication
The system SHALL support OAuth2 authentication for configured providers (Google, GitHub).

#### Scenario: OAuth2 login with Google
- **GIVEN** OAuth2 is configured for Google
- **WHEN** a user initiates Google login
- **THEN** the system SHALL redirect to Google's OAuth consent screen
- **AND** upon successful authorization, create or link a user account

#### Scenario: OAuth2 account linking
- **GIVEN** an existing user authenticated via password
- **WHEN** the user authenticates via OAuth2 with the same email
- **THEN** the system SHALL link the OAuth2 identity to the existing account
- **AND** not create a duplicate user

### Requirement: API Token Authentication
The system SHALL support long-lived API tokens for programmatic access using AshAuthentication.

#### Scenario: API token generation
- **GIVEN** an authenticated admin user
- **WHEN** the user requests a new API token
- **THEN** the system SHALL generate a cryptographically secure token
- **AND** store a hashed version in the database
- **AND** display the token exactly once

#### Scenario: API token authentication
- **GIVEN** a valid API token
- **WHEN** a request includes the token in the Authorization header
- **THEN** the system SHALL authenticate the request as the token's owner
- **AND** enforce the token's scope restrictions

### Requirement: Session Management
The system SHALL manage user sessions with configurable expiration and logout capabilities.

#### Scenario: Session expiration
- **GIVEN** a user session older than 30 days
- **WHEN** the user makes an authenticated request
- **THEN** the system SHALL reject the request
- **AND** require re-authentication

#### Scenario: Logout
- **WHEN** a user logs out
- **THEN** the system SHALL invalidate the current session token
- **AND** remove the session cookie

### Requirement: Migration from Phoenix.gen.auth
The system SHALL provide a migration path from the existing Phoenix.gen.auth implementation to AshAuthentication.

#### Scenario: Existing user migration
- **GIVEN** users in the ng_users table from Phoenix.gen.auth
- **WHEN** AshAuthentication is enabled
- **THEN** existing users SHALL be able to authenticate
- **AND** existing hashed passwords SHALL remain valid

### Requirement: Tenant-Aware Authentication Context
Authentication flows SHALL resolve tenant context from vanity domains when present. If no tenant is resolved and more than one tenant exists or no default tenant is configured, the system SHALL require an explicit tenant selection. The resolved tenant MUST be stored in session state and used to scope all authentication actions (magic link, password, and token validation). Single-tenant installations SHALL auto-select the default tenant without prompting.

#### Scenario: Vanity domain resolves tenant context
- **GIVEN** a request is made to a tenant-specific host (vanity domain)
- **WHEN** the login page is accessed
- **THEN** the system SHALL resolve the tenant from the host
- **AND** authentication actions SHALL be scoped to that tenant without prompting

#### Scenario: Multi-tenant login requires tenant selection
- **GIVEN** multiple tenants exist or no default tenant is set
- **WHEN** a user accesses the login page without a tenant-resolving host
- **THEN** the system SHALL prompt for a tenant slug or selection
- **AND** the selected tenant SHALL be stored in session and used for subsequent authentication actions

#### Scenario: Single-tenant login auto-selects default tenant
- **GIVEN** a default tenant is configured and only one tenant exists
- **WHEN** a user accesses the login page without a tenant-resolving host
- **THEN** the system SHALL not prompt for tenant selection
- **AND** the default tenant SHALL be used for authentication actions

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

