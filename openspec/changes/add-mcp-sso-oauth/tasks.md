## 1. Metadata and 401 discovery

- [x] 1.1 Serve RFC 9728 protected-resource metadata at
      `/.well-known/oauth-protected-resource` (and the MCP resource URL
      variant if required) with `authorization_servers`,
      `bearer_methods_supported: ["header"]`, and `scopes_supported`
      including `mcp` and `read`.
- [x] 1.2 Serve RFC 8414 authorization-server metadata at
      `/.well-known/oauth-authorization-server` listing authorize, token,
      `authorization_code`, `refresh_token`, `client_credentials`, and
      `S256`.
- [x] 1.3 Unauthenticated `/mcp` responses are HTTP 401 with
      `WWW-Authenticate` including `resource_metadata` pointing at (1.1).
- [x] 1.4 Tests: metadata JSON shape; 401 header present when MCP is on;
      404 and no metadata requirement when MCP is off.

## 2. Authorization code + PKCE

- [x] 2.1 Ash resources (platform schema) for authorization codes, grants,
      and refresh tokens. Grants store `auth_method`, `idp_iss`,
      `idp_sid`, and encrypted IdP refresh when present. Migrations in
      `serviceradar_core`.
- [x] 2.2 First-party public client `serviceradar-mcp` with RFC 8252
      loopback redirect URIs only.
- [x] 2.3 `GET /oauth/authorize`: require `response_type=code`,
      `client_id=serviceradar-mcp` (v1), `redirect_uri` loopback,
      `code_challenge` S256, `scope` including `mcp`. Unauthenticated
      browsers redirect to existing log-in with `return_to`.
- [x] 2.4 Consent LiveView after session login. Approve issues a one-time
      code; Deny returns OAuth error to redirect_uri. Repeat consent can
      be skipped while a grant is active.
- [x] 2.5 LoginPolicy is unchanged: OIDC/SAML/password as configured
      (Authentik on demo). Authorize MUST NOT bypass SSO. Consent copies
      IdP `sid` / SessionIndex (and IdP refresh if issued) onto the grant.
- [x] 2.6 Tests: PKCE missing/plain rejected; bad redirect rejected;
      unauthenticated hits log-in; SSO session can approve; code is
      single-use; grant stores `idp_sid` after OIDC login.

## 3. Token endpoint

- [x] 3.1 `POST /oauth/token` accepts `grant_type=authorization_code` with
      `code`, `redirect_uri`, `client_id`, `code_verifier`. Issues
      Guardian API JWT (`mcp` + `read`) for the consenting user. Issue a
      refresh token only when the grant has IdP session binding (or is
      local-password).
- [x] 3.2 `grant_type=refresh_token` rotates refresh; reuse of a rotated
      token revokes the family. For OIDC/SAML grants, confirm the IdP
      session is still valid before minting a new access token; on failure
      return `invalid_grant` and revoke the family. If SSO produced no
      session id and no IdP refresh, do not issue an MCP refresh token.
- [x] 3.3 Honor OIDC back-channel logout / SAML SLO: revoke MCP grants
      whose `idp_sid` matches. Do not wait for the next refresh.
- [x] 3.4 `grant_type=client_credentials` unchanged unless
      `mcp.clientCredentialsEnabled` is false, in which case mcp-scoped
      client_credentials is `unauthorized_client`.
- [x] 3.5 Access token TTL 1 hour. Refresh TTL configurable (default 8
      hours) as a backstop; IdP session is the SSO control.
- [x] 3.6 `/mcp` accepts the new JWT exactly as today's mcp-scoped Bearer.
      Actor is the SSO user. No SystemActor. Cookies still rejected.
- [x] 3.7 Tests: happy path code -> MCP initialize/tools/list; refresh
      while IdP session live; refresh after simulated IdP logout fails;
      SLO revokes grant; missing sid => no refresh_token; reuse-revokes;
      client_credentials kill switch; password grant is not documented or
      required for MCP.

## 4. Settings, audit, rate limits

- [x] 4.1 User can list and revoke MCP OAuth grants/sessions in Settings
      (API Credentials or sibling page).
- [x] 4.2 `SecurityEvent` kinds for authorize success/deny, token issue,
      refresh, grant revoke, IdP-session refresh denial, and SLO revoke,
      in addition to existing `mcp_*` kinds. Never persist IdP tokens.
- [x] 4.3 Rate-limit authorize and token separately from `:mcp` tool
      traffic.
- [x] 4.4 Helm/AuthorizationSettings: refresh TTL, loopback client id,
      `mcp.clientCredentialsEnabled`. Demo Authentik: session `sid` and
      IdP refresh/`offline_access` if not already requested by the web
      OIDC client.

## 5. Docs and verification

- [x] 5.1 Update `docs/docs/mcp-integration.md`: SSO login vs client
      credentials; Codex / Claude Code / Grok config using OAuth login;
      `client_id=serviceradar-mcp`; 1h access; refresh only while the IdP
      session is alive; logout/SLO forces `mcp login` again; how to
      disable client_credentials.
- [x] 5.2 Conn tests against srql-fixtures (or ConnCase) for metadata,
      authorize redirect, token, and MCP tools as the SSO user. Do not
      use live demo as the test oracle.
- [ ] 5.3 Manual demo path (operator): enable MCP, `codex mcp login` (or
      equivalent) against `https://demo.serviceradar.cloud/mcp`, complete
      Authentik, tools/list as that user.
