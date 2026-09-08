## ADDED Requirements

### Requirement: MCP OAuth authorize uses the browser login session
`GET /oauth/authorize` for MCP MUST authenticate the user with the same browser session and LoginPolicy as the web UI. If no session exists, the system MUST redirect to the existing log-in path with a return URL back to authorize. Completing log-in (OIDC, SAML, or password as configured) MUST resume authorize. The system MUST NOT implement a parallel login form for MCP.

#### Scenario: Logged-out authorize goes to existing log-in
- **GIVEN** no browser session
- **WHEN** a user-agent opens `/oauth/authorize` with a valid MCP auth-code request
- **THEN** the response is a redirect to the existing `/users/log-in` (or equivalent) with `return_to` set to the authorize request

#### Scenario: SSO login resumes authorize
- **GIVEN** OIDC SSO is the configured login
- **WHEN** the user completes OIDC and lands back on authorize
- **THEN** the system treats them as the SSO user for consent
- **AND** does not prompt for a local password
- **AND** the resulting MCP grant stores the IdP session identifier from the login (OIDC `sid` or SAML SessionIndex) when present

### Requirement: MCP OAuth refresh consults the IdP session
For MCP grants whose `auth_method` is OIDC or SAML, `POST /oauth/token` with `grant_type=refresh_token` MUST use the stored IdP session binding (session id and/or encrypted IdP refresh token) to verify the identity provider still holds that session. A failed IdP check MUST be treated as `invalid_grant` and MUST revoke the ServiceRadar refresh family. The system MUST NOT mint a new Guardian access token from refresh alone when SSO created the grant.

#### Scenario: Live IdP session allows MCP refresh
- **GIVEN** an MCP grant with a stored Authentik `sid` and a still-valid IdP session
- **WHEN** the client sends `grant_type=refresh_token`
- **THEN** ServiceRadar confirms the IdP session
- **AND** issues a new Guardian access token for the same user

#### Scenario: Dead IdP session denies MCP refresh
- **GIVEN** an MCP grant created via SSO
- **AND** the IdP session is no longer valid
- **WHEN** the client sends `grant_type=refresh_token`
- **THEN** no new access token is issued
- **AND** the refresh family is revoked

### Requirement: MCP OAuth consent is explicit and revocable
Before issuing an authorization code, the system MUST show a consent page naming the client and requested scopes (`mcp` and `read` in v1). Approve MUST bind the grant to the signed-in user. Deny MUST return an OAuth error to the redirect URI. The user MUST be able to revoke the grant from Settings, after which refresh and remaining access for that grant fail.

#### Scenario: Approve issues a code to loopback
- **GIVEN** a signed-in user on the MCP consent page
- **WHEN** they approve `mcp` and `read` for `serviceradar-mcp`
- **THEN** the browser redirects to the requested loopback URI with a one-time `code` and the original `state`

#### Scenario: Deny returns an OAuth error
- **GIVEN** a signed-in user on the MCP consent page
- **WHEN** they deny
- **THEN** the browser redirects to the loopback URI with an OAuth error
- **AND** no authorization code is issued

#### Scenario: Revoked grant cannot refresh
- **GIVEN** the user revoked the MCP grant in Settings
- **WHEN** the client presents the grant's refresh token
- **THEN** the token request fails
- **AND** subsequent `/mcp` calls with the old access token fail once that access token is rejected or expired
