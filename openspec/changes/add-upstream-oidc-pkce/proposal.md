# Change: Add PKCE S256 to the upstream OIDC authorization-code flow

GitHub: https://github.com/carverauto/serviceradar/issues/4256

## Why

web-ng's upstream OIDC client is a confidential server-side web application
that already uses the authorization-code flow with a client secret, `state`,
and `nonce`. It does not send a PKCE `code_challenge` on `/auth/oidc` or a
`code_verifier` on token exchange.

That is below current IdP guidance. Microsoft Entra documents the supported
user-interactive profile as "OIDC Authorization Code + PKCE" and recommends
PKCE for confidential clients. Entra still accepts this Web flow without
PKCE today; enterprise policy may require it later. RFC 7636 and OAuth 2.1
treat PKCE as the standard defense against authorization-code interception.

ServiceRadar already requires PKCE S256 on its **MCP OAuth authorization
server** (`GET /oauth/authorize`). That is a different flow: ServiceRadar is
the AS, the MCP client is public. This change is the **upstream OIDC client**
talking to Entra / Authentik / a generic IdP. Do not conflate the two.

## What Changes

- Generate an RFC 7636 S256 verifier at authorize time. Derive a
  base64url-without-padding SHA-256 challenge. Send `code_challenge` and
  `code_challenge_method=S256` on the authorization request.
- Keep the verifier only in the encrypted server-side login session, bound
  to the same `state` (and `nonce`) already stored there. Consume and delete
  it on callback **before** any token request. Never log it, never copy it
  into identity claims.
- Send `code_verifier` on the confidential-client token exchange **in
  addition to** the existing client secret. PKCE does not replace secret
  authentication.
- Fail closed when a PKCE login's verifier is missing, stale, replayed, or
  belongs to another attempt. A callback that still has a valid `state` /
  `nonce` after the verifier was consumed MUST NOT fall through to
  `exchange_code/2`.
- Provider compatibility is explicit and configurable on AuthSettings
  (`oidc_pkce_mode`) and **Settings -> Authentication** (OIDC form):
  - Default `auto`: send S256 when discovery advertises it **or** omits
    `code_challenge_methods_supported`. If discovery lists methods and
    omits `S256`, skip PKCE (never `plain`) and warn.
  - `required`: always send S256; refuse to start login when discovery
    advertises methods without `S256`.
  - `disabled`: never send PKCE (escape hatch for a provider that rejects
    `code_verifier`).
- Document upstream PKCE in `docs/docs/auth-configuration.md` and
  distinguish it from MCP OAuth PKCE. Validate the flow against a Microsoft
  Entra Web application registration.

**Not in this change:** MCP OAuth, CLI `--web` PKCE, or SAML. PKCE mode is
not an env var; operators set it next to the OIDC client id and secret.

## Impact

- Affected specs: `ash-authentication`
- Affected code:
  - `elixir/web-ng/lib/serviceradar_web_ng_web/auth/oidc_client.ex`
  - `elixir/web-ng/lib/serviceradar_web_ng_web/controllers/oidc_controller.ex`
  - `elixir/web-ng/lib/serviceradar_web_ng/mcp/oauth/pkce.ex` (shared S256
    helper lift only; MCP authorize/token behavior unchanged)
  - `elixir/web-ng/test/phoenix/auth/oidc_client_test.exs`
  - `elixir/web-ng/test/phoenix/controllers/oidc_controller_test.exs`
  - `elixir/web-ng/lib/serviceradar_web_ng_web/live/settings/authentication_live.ex`
  - `elixir/serviceradar_core` AuthSettings + migration
  - `docs/docs/auth-configuration.md`
- Schema: Ecto migration adds `platform.auth_settings.oidc_pkce_mode`
  (default `auto`). The committed baseline dump is older than this
  migration (`included_through` 20260707120000), so the column is not
  patched into `platform_schema.sql`; fresh installs get it from the
  post-baseline migration.
- Existing `state` / `nonce` tests MUST keep passing.
