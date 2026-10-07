# ash-authentication Specification

## Purpose
Provide user identity, authentication strategies, and session management using the AshAuthentication framework.

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

### Requirement: Upstream OIDC authorization-code flow uses PKCE S256
The web-ng upstream OIDC client MUST use Proof Key for Code Exchange
(RFC 7636) with `code_challenge_method=S256` when talking to a
PKCE-capable identity provider. This is the confidential-client login
at `GET /auth/oidc` and `GET /auth/oidc/callback`. It is distinct from
ServiceRadar's MCP OAuth authorization server, which already requires
PKCE S256 of public MCP clients.

A PKCE login MUST:

1. Generate a cryptographically random verifier of at least 32 bytes,
   encoded as base64url without padding (RFC 7636 unreserved alphabet,
   length 43 to 128).
2. Derive the challenge as BASE64URL(SHA-256(verifier)) without padding.
3. Send `code_challenge` and `code_challenge_method=S256` on the
   authorization request.
4. Keep the verifier only in the encrypted server-side login session,
   bound to the same `state` (and `nonce`) for that attempt.
5. Consume and delete the verifier, `state`, `nonce`, and PKCE flag
   from the session on callback before any token request.
6. Send `code_verifier` on the authorization-code token exchange
   together with the existing client secret.
7. Fail the callback without calling the token endpoint when the
   verifier is absent, empty, stale, replayed, or bound to a different
   `state`.

The client MUST NOT send `code_challenge_method=plain`. The client
MUST NOT log the verifier, include it in identity claims, or copy it
into audit metadata.

PKCE mode is stored on AuthSettings as `oidc_pkce_mode` and MUST be
editable under Settings -> Authentication on the OIDC form. Values are
`auto` (default), `required`, or `disabled`:

- `auto`: send S256 when discovery `code_challenge_methods_supported`
  includes `S256`, or when that field is absent. If the field is
  present and does not include `S256`, omit PKCE and do not send
  `plain`.
- `required`: always send S256; refuse to start login when discovery
  advertises challenge methods that do not include `S256`.
- `disabled`: never send PKCE (compatibility path for a provider that
  rejects `code_verifier`).

Existing `state` and `nonce` checks remain mandatory on every callback.

#### Scenario: PKCE-capable provider receives an S256 challenge
- **GIVEN** Direct SSO OIDC is enabled
- **AND** discovery metadata includes `code_challenge_methods_supported`
  with `S256`
- **WHEN** a user starts login at `GET /auth/oidc`
- **THEN** the authorization redirect includes `code_challenge` derived
  with S256 and `code_challenge_method=S256`
- **AND** the matching verifier is stored only in the login session
  next to `state` and `nonce`

#### Scenario: Token exchange sends verifier and client secret
- **GIVEN** a PKCE login whose session still holds the verifier bound
  to the callback `state`
- **WHEN** `GET /auth/oidc/callback` receives that `state` and an
  authorization code
- **THEN** the token request includes `code_verifier` and `client_secret`
- **AND** the verifier, `state`, `nonce`, and PKCE flag are deleted
  from the session before the token request is sent

#### Scenario: Consumed verifier cannot be reused
- **GIVEN** a PKCE login whose callback already consumed the session
  verifier
- **WHEN** the same callback URL is replayed, or a second callback
  arrives with a matching `state` but no verifier
- **THEN** the handler does not call the token endpoint
- **AND** the user is sent back to sign-in with an authentication
  failure

#### Scenario: Provider without advertised S256 uses the compatibility path
- **GIVEN** PKCE mode is `auto`
- **AND** discovery lists `code_challenge_methods_supported` without
  `S256`
- **WHEN** a user starts login
- **THEN** the authorization request omits `code_challenge`
- **AND** the token request omits `code_verifier`
- **AND** `plain` is never sent

#### Scenario: Operators set PKCE mode in authentication settings
- **GIVEN** Direct SSO OIDC is the configured login
- **WHEN** an administrator opens Settings -> Authentication
- **THEN** the OIDC form offers Auto, Required, and Disabled PKCE modes
- **AND** saving the form persists `oidc_pkce_mode` on AuthSettings

#### Scenario: Methods field absent still uses S256 under auto
- **GIVEN** PKCE mode is `auto`
- **AND** discovery metadata omits `code_challenge_methods_supported`
- **WHEN** a user starts login
- **THEN** the authorization request includes `code_challenge_method=S256`

#### Scenario: Disabled mode skips PKCE
- **GIVEN** AuthSettings `oidc_pkce_mode` is `disabled`
- **WHEN** a user starts OIDC login
- **THEN** the authorization request omits `code_challenge`
- **AND** the token request omits `code_verifier`
- **AND** `state` and `nonce` validation still run

#### Scenario: Verifier is not logged or copied into claims
- **GIVEN** a successful PKCE login
- **WHEN** the session is created from the verified ID token
- **THEN** identity claims and auth audit events do not contain the
  verifier
- **AND** application logs do not contain the verifier
