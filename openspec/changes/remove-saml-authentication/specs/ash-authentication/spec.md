## ADDED Requirements

### Requirement: Direct SSO Uses OIDC Only
The system SHALL offer OpenID Connect as the only direct single sign-on protocol; it MUST NOT accept SAML sign-in.
Local password accounts and Gateway Proxy (JWT) mode remain available. The stored direct-SSO provider type
accepts only `oidc`, and Settings -> Authentication offers no other provider.

#### Scenario: Former SAML endpoints are not routed
- **WHEN** a client requests `GET /auth/saml`, `POST /auth/saml/consume` or `GET /auth/saml/metadata`
- **THEN** web-ng responds with HTTP 404
- **AND** no SAML response is parsed and no session is created

#### Scenario: Saving direct SSO stores the OIDC provider
- **GIVEN** an administrator with `settings.auth.manage`
- **WHEN** the administrator saves Settings -> Authentication in Direct SSO mode
- **THEN** the stored provider type is `oidc`
- **AND** the settings form offers no SAML fields

### Requirement: Upgrade Moves Stored SAML Configuration To Local Login
The system SHALL migrate a database that stored SAML authentication state so that the upgraded installation boots and permits local password login.
The schema migration MUST be idempotent, bounded and safe on a database that never stored SAML data.

#### Scenario: SAML-configured settings fall back to password-only
- **GIVEN** auth settings with mode `active_sso` and provider type `saml`
- **WHEN** the upgrade migration runs
- **THEN** the settings mode is `password_only`, SSO is disabled and the provider type is empty
- **AND** an administrator with a local password can sign in

#### Scenario: SAML schema objects are dropped
- **WHEN** the upgrade migration runs
- **THEN** the `saml_pending_requests` and `saml_consumed_assertions` tables no longer exist
- **AND** the `auth_settings` SAML columns (IdP metadata URL and XML, SP entity ID, encrypted SP private key, pinned certificate fingerprints) no longer exist
- **AND** no pending job for the removed SAML assertion cleanup worker remains

#### Scenario: SAML-provisioned users keep their accounts
- **GIVEN** a user provisioned through SAML whose last authentication method is recorded as `saml`
- **WHEN** the upgrade migration runs
- **THEN** the user's account, role, role profile and external identifier are unchanged
- **AND** the recorded last authentication method is cleared so the account still loads
- **AND** the user's first OIDC sign-in whose mapped `sub` claim equals the stored external identifier signs into that account

#### Scenario: SAML-bound MCP grants are revoked
- **GIVEN** an MCP OAuth grant created from a SAML session
- **WHEN** the upgrade migration runs
- **THEN** the grant and its authorization codes and refresh tokens are deleted
- **AND** the user must authorize the MCP client again after signing in
