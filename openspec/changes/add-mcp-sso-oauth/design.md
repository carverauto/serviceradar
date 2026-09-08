## Context

`/mcp` is `AshAi.Mcp.Router` behind `ApiAuth` + `mcp` scope. Tokens today come
from `POST /oauth/token` `grant_type=client_credentials` (or a password grant
that SSO orgs should not use). Browser cookies are rejected on `/mcp`.

Claude Code, Codex, and Grok HTTP OAuth do **not** speak client credentials.
They:

1. GET `/mcp` (or the resource URL)
2. On 401, read `WWW-Authenticate` / fetch
   `/.well-known/oauth-protected-resource`
3. Discover the AS via RFC 8414
4. Open a browser at `authorization_endpoint` with PKCE
5. Exchange the code at `token_endpoint`
6. Send `Authorization: Bearer` on every MCP request
7. Refresh when the access token expires

Demo SSO is Authentik OIDC (`forceLocalLogin: false`). Production customers
use the same LoginPolicy (OIDC/SAML). The MCP client must not talk to
Authentik's token endpoint with a ServiceRadar client secret; ServiceRadar
must run authorize so LoginPolicy applies, then issue the JWT `ApiAuth`
already understands.

## Goals / Non-Goals

- Goals:
  - `codex mcp login` / Claude HTTP OAuth / Grok HTTP OAuth complete against
    a ServiceRadar origin (demo or production) using the **same SSO** as the
    UI.
  - Access tokens on `/mcp` stay Guardian JWTs; actor is the SSO user;
    RBAC unchanged.
  - PKCE S256 required. Refresh with rotation **and IdP-session binding**
    when the grant was created through SSO.
  - Client credentials remain for farm01 and non-SSO automation.
- Non-Goals:
  - Validating customer IdP (Authentik/Okta/Entra) access tokens on `/mcp`.
  - Dynamic client registration (RFC 7591) or CIMD.
  - `ash_authentication_oauth2_server` as a second authorization server.
  - Device-code for MCP (CLI already has device-code; MCP clients use
    auth-code + loopback).
  - Turning MCP on by default or flipping demo without an operator.

## Decisions

- Decision: ServiceRadar is the MCP authorization server; authorize
  federates to existing SSO.
  - Rationale: `/mcp` and `ApiAuth` already require Guardian + `mcp` + a
    real user. Pointing MCP clients at Authentik would make IdP JWTs the
    bearer, which `ApiAuth` rejects, and would skip ServiceRadar RBAC unless
    we grew a second token validator. Authorize-then-Guardian keeps one
    actor model.
  - Alternative (later): IdP as AS, ServiceRadar as RS only. Needed when a
    tenant forbids any app-issued token. Out of scope here.

- Decision: First-party public client `serviceradar-mcp`, not DCR.
  - Rationale: Native MCP clients are public (no confidential secret). The
    CLI already special-cases `serviceradar-cli`. A well-known public
    `client_id` plus RFC 8252 loopback redirect URIs unblocks Codex/Claude
    Code/Grok without standing up DCR. Hosted Claude.ai connectors that
    insist on DCR are a follow-up.
  - Loopback: `http://127.0.0.1:<port>/...` and `http://localhost:<port>/...`
    with any path, any port, for `serviceradar-mcp` only. No other http
    redirects. https redirect URIs for that client are not required in v1.

- Decision: PKCE S256 is mandatory on authorization_code.
  - Rationale: Public clients cannot protect a secret. `plain` PKCE is
    rejected. Missing `code_challenge` is 400.

- Decision: Consent is an explicit LiveView after session login.
  - Rationale: SSO proves who the user is; consent proves they meant to
    give **this** native client `mcp` (and `read`). Mirror CLI device
    approve. Persist grants so the second login from the same client can
    skip consent until revoked. Revoke from Settings (API Credentials or a
    sibling MCP sessions list).

- Decision: Access token TTL stays 1 hour; refresh tokens rotate **and
  bind to the IdP session**.
  - Rationale: A rotating ServiceRadar refresh token alone is still
    "SSO once, then silent app-issued tokens." Reviews that require SSO on
    every grant will reject that. Short TTL is not a substitute: an 8h
    refresh still outlives an Authentik logout. The grant MUST store the
    IdP session identifier (`sid` on OIDC id_token, SAML `SessionIndex`)
    and, when the IdP issued one, an encrypted IdP refresh token. On
    `grant_type=refresh_token` the server MUST confirm that IdP session is
    still valid (IdP token refresh and/or introspection / userinfo) before
    minting a new Guardian access token. If the IdP session is gone, MCP
    refresh fails (`invalid_grant`) and the refresh family is revoked; the
    client must run authorize again (browser + SSO). Back-channel OIDC
    logout / SAML SLO for that `sid` MUST revoke matching MCP grants
    immediately, not wait for the next refresh. Local-password-only
    deployments have no IdP session: refresh is TTL + rotation only.
  - Fail closed: if the login method is OIDC/SAML but the IdP did not
    provide a session id or a way to check it, do not issue an MCP refresh
    token (access token only, 1h). Do not silently unbound-refresh.
  - Default refresh TTL remains 8 hours as a backstop, not as the SSO
    control.

- Decision: Keep `client_credentials`; add a kill switch.
  - Rationale: Farm01 and scripts use it. SSO-mandated deployments set
    `mcp.clientCredentialsEnabled: false` (Helm / AuthorizationSettings).
    When false, `grant_type=client_credentials` for tokens that include
    `mcp` is 400 `unauthorized_client`. Other API clients (read/write
    without mcp) are unchanged.

- Decision: Implement with existing Phoenix + Guardian, not a second OAuth
  library.
  - Rationale: `OAuthController` already issues API JWTs. Adding authorize,
    codes, and refresh next to it avoids `ash_authentication_oauth2_server`
    as a parallel AS. Revisit only if PKCE/metadata cannot be done
    correctly in-process.

- Decision: Unauthenticated `/mcp` 401 includes RFC 9728
  `WWW-Authenticate`.
  - Rationale: MCP clients will not start OAuth if they only see JSON
    `{"error":"unauthorized"}` with no metadata URL.

## Token and table shape

Authorization code (short-lived, single use):

- `code_hash`, `client_id`, `user_id`, `redirect_uri`, `code_challenge`,
  `code_challenge_method=S256`, `scope`, `expires_at` (~10 minutes)

Refresh token:

- `token_hash`, `family_id`, `client_id`, `user_id`, `scope`, `expires_at`,
  `revoked_at`, `grant_id`. Rotation: new row, previous hash revoked.
  Presenting a revoked family member revokes the whole family.

Access token:

- Existing `Guardian.create_api_token/2`, `typ` API, scopes include `mcp`,
  actor is the consenting user. Optional `jti` tied to the grant for
  revoke-all.

Grant:

- `user_id`, `client_id`, `scope`, `created_at`, `revoked_at`
- `auth_method` (`oidc` | `saml` | `password`)
- `idp_iss`, `idp_sid` (OIDC `sid` or SAML SessionIndex; required to
  *issue* a refresh token when `auth_method` is oidc/saml)
- encrypted IdP refresh token when the IdP issued one (Cloak; never log)
- IdP access token only if needed for introspection, same encryption,
  short-lived, replace on successful IdP refresh

## Happy-path sequence (demo)

1. User enables MCP on the deployment (`webNg.mcpEnabled=true`).
2. Codex: `[mcp_servers.serviceradar] url = "https://demo.serviceradar.cloud/mcp"`
   then `codex mcp login serviceradar`.
3. Codex GET `/mcp` -> 401 +
   `WWW-Authenticate: Bearer realm="mcp", resource_metadata="https://demo.serviceradar.cloud/.well-known/oauth-protected-resource"`.
4. Metadata lists `authorization_servers` =
   `https://demo.serviceradar.cloud` and
   `scopes_supported` including `mcp` and `read`.
5. AS metadata lists `authorization_endpoint` `/oauth/authorize`,
   `token_endpoint` `/oauth/token`,
   `grant_types_supported` including `authorization_code` and
   `refresh_token`, `code_challenge_methods_supported` = `S256`.
6. Browser opens `/oauth/authorize?response_type=code&client_id=serviceradar-mcp&redirect_uri=http://127.0.0.1:<port>/callback&code_challenge=...&code_challenge_method=S256&scope=mcp%20read&state=...`.
7. No session: redirect to `/users/log-in?return_to=...` -> Authentik OIDC
   -> `UserAuth.log_in_user` (existing).
8. Consent LiveView: "Codex / serviceradar-mcp wants Read and MCP." Approve.
9. Redirect to loopback with `code` and `state`.
10. Codex POST `/oauth/token` `grant_type=authorization_code` + verifier.
11. Response `{access_token, token_type: Bearer, expires_in: 3600,
    refresh_token, scope: "mcp read"}`. Grant stores Authentik `sid` (and
    IdP refresh if present).
12. MCP initialize / tools/list as today, actor = SSO user.
13. After 1h, Codex POSTs `grant_type=refresh_token`. ServiceRadar
    refreshes/introspects the Authentik session for that `sid`. If
    Authentik still has the session, a new Guardian access token is
    issued. If the user logged out of Authentik, or SLO arrived, refresh
    is `invalid_grant` and Codex must `mcp login` again.

## Risks / Trade-offs

- Risk: MCP clients try DCR and fail.
  - Mitigation: document `client_id=serviceradar-mcp`. If a client requires
    DCR, that is the next change, not a silent fallback to client
    credentials.
- Risk: Refresh without a live IdP session is still "SSO once then silent."
  - Mitigation: refresh MUST check the IdP session (and SLO must revoke
    grants). This is MFA-on-grant plus "IdP session still alive," not
    MFA-on-every-MCP-call. Access tokens remain valid until their 1h TTL
    even after logout; that is the same as today's browser session
    cookies unless we add token revocation lists for access JWTs (out of
    scope; keep TTL short).
- Risk: IdP does not send `sid` / SessionIndex or IdP refresh.
  - Mitigation: fail closed — no MCP refresh token, 1h access only, client
    re-authorizes. Do not fall back to unbound refresh. Configure
    Authentik (demo) to include session claims / `offline_access` as
    needed.
- Risk: Loopback redirect open redirector.
  - Mitigation: only `serviceradar-mcp` may use RFC 8252 loopback; host must
    be 127.0.0.1 or localhost; scheme http; no userinfo.
- Risk: Client credentials remain a policy hole if left on.
  - Mitigation: explicit disable flag; docs for SSO orgs to turn it off.
- Risk: `password` grant used instead of SSO.
  - Mitigation: unchanged LoginPolicy; do not advertise password for MCP.

## Migration Plan

1. Ship metadata + authorize + token grants behind the existing MCP feature
   flag (no new default-on surface).
2. Keep client credentials default-on.
3. Demo: operator enables MCP, users run `codex mcp login` / Claude HTTP
   OAuth against `https://demo.serviceradar.cloud/mcp`.
4. Rollback: disable MCP flag or revert; leftover code/grant rows are
   unused. Client-credentials clients keep working.

## Open Questions

- Should hosted Claude.ai (DCR) be a fast-follow in the same release, or
  wait for a customer?
- Settings UI: extend API Credentials vs a dedicated "MCP sessions" page?
- Demo Authentik: confirm `sid` on id_token and whether we already request
  a refresh token on the web OIDC client; if not, that is a config task
  in this change, not a reason to unbound MCP refresh.
