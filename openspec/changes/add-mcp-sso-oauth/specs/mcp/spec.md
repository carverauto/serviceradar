## ADDED Requirements

### Requirement: MCP authorization-code login uses existing SSO
The system SHALL support OAuth 2.0 authorization-code with PKCE (S256) so an MCP client can obtain a Guardian API access token after the user signs in through the same LoginPolicy as the web UI (OIDC, SAML, or local login as configured). The authorization endpoint MUST be on the ServiceRadar origin. The system MUST NOT require a long-lived client secret in the MCP client for this grant. The system MUST NOT accept an identity-provider access token as an `/mcp` bearer in this change.

#### Scenario: Codex-style login completes through SSO
- **GIVEN** MCP is enabled
- **AND** the deployment uses OIDC SSO (for example Authentik on demo)
- **WHEN** an MCP client starts authorization-code + PKCE against `/oauth/authorize` with `client_id=serviceradar-mcp` and a loopback redirect URI
- **THEN** an unauthenticated browser is sent through the existing log-in path
- **AND** after SSO and consent the client receives an authorization code
- **AND** `POST /oauth/token` with `grant_type=authorization_code` and the PKCE verifier returns a Bearer access token whose actor is the SSO user

#### Scenario: IdP access tokens are not MCP bearers
- **GIVEN** a valid Authentik (or other IdP) access token
- **WHEN** a client calls `/mcp` with `Authorization: Bearer` set to that token
- **THEN** the request is not authenticated as a ServiceRadar user
- **AND** the response is HTTP 401

#### Scenario: LoginPolicy is not bypassed
- **GIVEN** SSO is enforced and local password login is disabled
- **WHEN** an MCP client starts authorization-code
- **THEN** the user cannot complete authorize with a local password
- **AND** they complete it with the configured SSO method

### Requirement: MCP OAuth discovery metadata
When MCP is enabled, the system SHALL publish RFC 9728 protected-resource metadata and RFC 8414 authorization-server metadata on the ServiceRadar origin so MCP clients can discover authorize and token endpoints. Unauthenticated calls to `/mcp` MUST return HTTP 401 with a `WWW-Authenticate` header whose `resource_metadata` parameter points at the protected-resource metadata URL.

#### Scenario: Protected resource metadata names the AS
- **GIVEN** MCP is enabled
- **WHEN** a client GET `/.well-known/oauth-protected-resource`
- **THEN** the document includes `authorization_servers` for this origin
- **AND** `scopes_supported` includes `mcp` and `read`
- **AND** `bearer_methods_supported` includes `header`

#### Scenario: AS metadata names authorize and token
- **GIVEN** MCP is enabled
- **WHEN** a client GET `/.well-known/oauth-authorization-server`
- **THEN** the document includes `authorization_endpoint` ending in `/oauth/authorize`
- **AND** `token_endpoint` ending in `/oauth/token`
- **AND** `grant_types_supported` includes `authorization_code` and `refresh_token`
- **AND** `code_challenge_methods_supported` includes `S256`

#### Scenario: Unauthenticated MCP points at metadata
- **GIVEN** MCP is enabled
- **WHEN** a client calls `/mcp` without credentials
- **THEN** the response is HTTP 401
- **AND** `WWW-Authenticate` includes a `resource_metadata` URL on this origin

#### Scenario: Disabled MCP does not advertise MCP OAuth
- **GIVEN** MCP is not enabled
- **WHEN** a client calls `/mcp`
- **THEN** the response is HTTP 404
- **AND** MCP tools remain unreachable

### Requirement: MCP PKCE public client
Authorization-code requests for the first-party MCP client MUST use PKCE S256. The v1 MCP native client id MUST be `serviceradar-mcp`. Redirect URIs for that client MUST be RFC 8252 loopback (`http://127.0.0.1` or `http://localhost`, any port, any path). Other hosts, schemes, or userinfo MUST be rejected. Dynamic client registration is not required in this change.

#### Scenario: S256 is required
- **WHEN** `/oauth/authorize` is called without `code_challenge` or with `code_challenge_method=plain`
- **THEN** the request is rejected
- **AND** no authorization code is issued

#### Scenario: Non-loopback redirect is rejected
- **WHEN** `serviceradar-mcp` requests `redirect_uri=https://evil.example/callback`
- **THEN** authorize is rejected
- **AND** no code is issued

#### Scenario: Loopback redirect is accepted
- **WHEN** `serviceradar-mcp` requests `redirect_uri=http://127.0.0.1:4321/callback`
- **AND** PKCE S256 parameters are valid
- **THEN** authorize may proceed to login/consent

### Requirement: MCP access tokens remain Guardian JWT with mcp scope
Tokens issued by the authorization-code grant MUST be Guardian API tokens that `/mcp` already accepts. They MUST include the `mcp` scope and MUST authenticate as the consenting user. Browser session cookies MUST still not authenticate `/mcp`. Refresh tokens MUST rotate; presenting a already-rotated refresh token MUST revoke that token family.

#### Scenario: Auth-code token can initialize MCP
- **GIVEN** a user completed SSO consent for `serviceradar-mcp`
- **WHEN** the client uses the issued access token on `/mcp` initialize
- **THEN** the server responds as MCP
- **AND** Ash sees that user as actor

#### Scenario: Refresh rotates when the IdP session is still valid
- **GIVEN** the grant was created via OIDC or SAML
- **AND** the IdP session bound to that grant is still valid
- **WHEN** a client exchanges a valid refresh token
- **THEN** a new access token and a new refresh token are issued
- **AND** the previous refresh token is no longer valid

#### Scenario: Refresh reuse revokes the family
- **WHEN** a client presents a refresh token that was already rotated
- **THEN** the response is an OAuth token error
- **AND** remaining tokens in that family are revoked

### Requirement: MCP refresh is bound to the IdP session
When the user authenticated authorize via OIDC or SAML, an MCP refresh token MUST be bound to that identity-provider session (OIDC `sid` and/or SAML SessionIndex, plus an IdP refresh token when the IdP issued one). `grant_type=refresh_token` MUST confirm the IdP session is still valid before issuing a new access token. If the IdP session is expired, logged out, or revoked, refresh MUST fail and the ServiceRadar refresh family MUST be revoked. IdP back-channel logout or SAML SLO for that session MUST revoke matching MCP grants immediately. If SSO was used but the IdP did not provide a session identifier or a checkable credential, the system MUST NOT issue an MCP refresh token (access token only). Local-password-only grants MAY refresh until TTL without an IdP check.

#### Scenario: Authentik logout stops MCP refresh
- **GIVEN** user U completed MCP OAuth via Authentik
- **AND** U's Authentik session has ended (logout or admin revoke)
- **WHEN** the MCP client presents the refresh token
- **THEN** the token response is `invalid_grant`
- **AND** that refresh family is revoked
- **AND** the client must run authorization-code again (browser SSO)

#### Scenario: IdP SLO revokes grants without waiting for refresh
- **GIVEN** an MCP grant bound to IdP session S
- **WHEN** the IdP sends a logout for S
- **THEN** the grant and its refresh family are revoked
- **AND** a later refresh for that family fails

#### Scenario: Missing IdP session id means no refresh token
- **GIVEN** the user signed in via OIDC
- **AND** the id_token has no `sid` and the IdP issued no refresh token
- **WHEN** `POST /oauth/token` completes authorization_code
- **THEN** an access token is issued
- **AND** no `refresh_token` is returned

#### Scenario: Local-password grant refreshes without IdP
- **GIVEN** the deployment has no SSO and the user signed in with a password
- **WHEN** the client refreshes before TTL
- **THEN** a new access token is issued without an IdP round-trip

### Requirement: MCP client-credentials can be disabled
The system SHALL keep `grant_type=client_credentials` available by default. A deployment setting MUST exist to reject client-credentials token requests that include the `mcp` scope, so SSO-mandated installs can forbid non-SSO MCP grants without removing API clients used for non-MCP HTTP.

#### Scenario: Default still allows client credentials
- **GIVEN** the kill switch is not set (default)
- **WHEN** a user-owned OAuth client with scope `mcp` calls `POST /oauth/token` with `grant_type=client_credentials`
- **THEN** an access token is issued as today

#### Scenario: SSO-mandated install rejects mcp client credentials
- **GIVEN** `mcp.clientCredentialsEnabled` is false
- **WHEN** a client requests `grant_type=client_credentials` with scope `mcp`
- **THEN** the response is OAuth `unauthorized_client`
- **AND** authorization-code for MCP still works
