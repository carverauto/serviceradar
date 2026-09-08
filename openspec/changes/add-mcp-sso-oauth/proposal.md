# Change: MCP OAuth login through existing SSO

## Why

MCP on web-ng authenticates with OAuth2 **client credentials**: a long-lived
`client_id` / `client_secret` minted in Settings, then `POST /oauth/token`
with no browser. That works for lab automation (farm01). It fails security
reviews that require every token grant to go through SSO (Authentik on
carverauto demo, customer IdP in production): MFA, conditional access, and
IdP revocation never see the agent. Claude Code, Codex, and Grok's HTTP OAuth
path (`codex mcp login`, Claude HTTP connector) expect authorization-code +
PKCE plus RFC 8414/9728 discovery, which `/mcp` does not advertise.

`add-ash-ai-mcp-server` deferred this on purpose (a second OAuth 2.1 server /
DCR). The facade, `mcp` scope, RBAC, and audit already exist. This change
adds the missing **authorization-code** grant so an IDE can open a browser,
the user signs in with the same LoginPolicy as the UI, and the client
receives a Guardian JWT. Client credentials stay for non-SSO installs.

## What Changes

- Publish MCP resource metadata (RFC 9728) and authorization-server metadata
  (RFC 8414) so clients can discover `/oauth/authorize` and `/oauth/token`.
- Add `GET /oauth/authorize` (authorization-code + PKCE S256). Unauthenticated
  browsers follow the existing log-in path (OIDC/SAML/password per
  LoginPolicy). After sign-in, a consent page names the client and scopes.
- Extend `POST /oauth/token` with `authorization_code` and `refresh_token`.
  Access tokens remain Guardian JWTs with `mcp` (and `read`) and the
  approving user as actor. Refresh tokens rotate **and, when the user signed
  in via SSO, are bound to that IdP session**: a refresh MUST fail if the
  IdP session is gone (logout, expiry, admin revoke). `client_credentials`
  remains; it can be disabled per deployment for SSO-mandated installs.
- Unauthenticated `/mcp` returns HTTP 401 with `WWW-Authenticate` pointing at
  the protected-resource metadata URL (MCP authorization spec).
- First-party public client `serviceradar-mcp` for native MCP clients
  (loopback redirect URIs). Dynamic client registration is **out of scope**.
- Consent/grants are revocable in Settings. Audit authorize, token, and
  refresh on `SecurityEvent`.
- Docs: Claude Code, Codex, Grok, and Claude Desktop configure OAuth login
  against demo (`https://demo.serviceradar.cloud/mcp`) once MCP is enabled.

**Not in this change:** accepting Authentik/IdP access tokens as `/mcp`
bearers (resource-server-to-customer-IdP). That is a later tenant option.
No `ash_authentication_oauth2_server` unless Phoenix + Guardian cannot
implement PKCE/metadata. No DCR/CIMD. No write tools. No enabling MCP on
demo by default (flag stays off; demo enablement is an operator choice).

## Impact

- Affected specs: `mcp`, `ash-authentication`, `ash-authorization`,
  `platform-security`
- Affected code:
  - `elixir/web-ng` (`OAuthController`, new authorize/consent LiveView,
    well-known routes, MCP 401 `WWW-Authenticate`, tests, docs)
  - `elixir/serviceradar_core` (authorization codes, refresh tokens, MCP
    OAuth grants with IdP session binding, `SecurityEvent` kinds, rate-limit
    buckets)
  - OIDC/SAML login: persist IdP `sid` / SessionIndex (and IdP refresh if
    issued) onto the MCP grant; honor back-channel / SLO logout by revoking
    those grants
  - `docs/docs/mcp-integration.md`
  - Helm values for redirect allowlists and optional
    `mcp.clientCredentialsEnabled`
- Migration: new tables for authorization codes, refresh tokens, and
  grants. Existing API clients and client-credentials tokens keep working.
