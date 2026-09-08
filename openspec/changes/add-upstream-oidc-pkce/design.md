## Context

`ServiceRadarWebNGWeb.Auth.OIDCClient` implements the confidential-client
authorization-code flow used by `GET /auth/oidc` and
`GET /auth/oidc/callback`. Today `authorize_url/1` sends `client_id`,
`redirect_uri`, `response_type=code`, `scope`, `state`, and `nonce`.
`exchange_code/2` posts `grant_type`, `code`, `client_id`, `client_secret`,
and `redirect_uri`. There is no PKCE.

The callback already stores `state` and `nonce` in the encrypted session
cookie (`SameSite=Lax`, required so the IdP top-level redirect still
presents the cookie) and deletes both before exchanging the code. Issue
#4256 adds a verifier beside those values. The review comment that
matters: a callback with a still-valid `state`/`nonce` after the verifier
was consumed or rotated MUST NOT silently exchange the code.

MCP already implements PKCE S256 as an **authorization server**
(`ServiceRadarWebNG.Mcp.OAuth.Pkce`). That code validates an inbound
challenge; it does not generate a client verifier. This change is the
upstream **client**. Share the S256 hash helper so the two implementations
cannot drift; do not route OIDC login through the MCP OAuth server.

## Goals / Non-Goals

- Goals:
  - Add RFC 7636 S256 to the upstream OIDC login for PKCE-capable providers.
  - Keep confidential-client secret authentication, `state`, and `nonce`.
  - Bind the verifier to the exact `state`, single-use, deleted before
    token exchange.
  - Give operators a documented compatibility path for providers that
    cannot do S256, without falling back to `plain`.
  - Cover challenge derivation, authorize params, token-exchange params,
    session cleanup, and failure paths with unit tests.
- Non-Goals:
  - Changing MCP OAuth, CLI device-auth, or SAML.
  - AuthSettings schema or Settings UI for PKCE mode.
  - Making PKCE replace the client secret.
  - Supporting `code_challenge_method=plain`.

## Decisions

- Decision: PKCE mode is `AuthSettings.oidc_pkce_mode` (`auto` | `required`
  | `disabled`, default `auto`), edited under **Settings -> Authentication**
  on the OIDC form.
  - Rationale: every other OIDC knob (discovery URL, client id, secret,
    scopes) already lives there. Operators should not need a process env
    to pick Auto vs Required vs Disabled. Env vars stay for break-glass
    (`SERVICERADAR_AUTH_FORCE_LOCAL_LOGIN`), not for IdP compatibility.
  - Alternatives considered:
    - Always-on, no flag: simpler, but silently breaks a generic OIDC
      install whose token endpoint rejects unknown form fields.
    - Hard-fail when discovery omits S256: too strict. Many metadata
      documents omit `code_challenge_methods_supported` while still
      accepting S256 (including older Entra documents).
    - Application env `SERVICERADAR_OIDC_PKCE_MODE`: rejected. It hides a
      login-policy choice from the authentication UI.

- Decision: `auto` sends S256 when discovery advertises `S256` **or** when
  `code_challenge_methods_supported` is absent. If the field is present and
  does not include `S256`, skip PKCE, never send `plain`, log a warning.
  `required` always sends S256 and refuses `authorize_url/1` when methods
  are advertised without `S256`. `disabled` never sends PKCE.
  - Rationale: answers the issue comment (config flag, not hard-fail by
    default) and the acceptance criterion (PKCE-capable providers get
    S256; non-advertising providers have a tested path).

- Decision: store `:oidc_code_verifier` and `:oidc_pkce` (boolean) in the
  same encrypted session as `:oidc_state` and `:oidc_nonce`. Delete all four
  on every callback path **before** `exchange_code/2`. The verifier is
  bound to the stored `state`: after consume, a replay or a second tab
  with the same callback URL fails because both `state` and verifier are
  gone. If `:oidc_pkce` was true and the verifier is missing or empty,
  fail with `:missing_pkce_verifier` and do not POST to the token endpoint.
  - Rationale: the current controller already deletes `state`/`nonce`
    before validation. That is the right single-use shape; PKCE must use
    it, not a later delete after a successful exchange.

- Decision: lift S256 challenge derivation into `ServiceRadarWebNG.Pkce`
  (`challenge_s256/1`, `generate_verifier/0`). MCP's module becomes a thin
  wrapper or call-site update. OIDC client generates a 32-byte CSPRNG
  verifier, base64url without padding (43 characters, unreserved alphabet).
  - Rationale: one hash implementation. MCP stays the AS; OIDC stays the
    client. 32 bytes matches the existing `state`/`nonce` generators.

- Decision: `exchange_code/2` takes `code_verifier` via opts and includes
  it in the form body only when present. The client secret is always sent
  for this confidential client. Existing token-exchange retry on a stale
  keep-alive (`:closed` before the request is written) may resend the same
  in-memory verifier; the session copy is already gone.
  - Rationale: retry exists because the first attempt never reached the
    IdP. Reusing the in-memory verifier on that retry is correct; reusing
    a session verifier across HTTP callbacks is not.

- Decision: verifiers MUST NOT appear in Logger output, `Hooks` metadata,
    `identity_claims`, or `UserAuthEvents`. Token-exchange error logs
    already print the **response** body; do not inspect the **request**
    form.
  - Rationale: the verifier is a credential. Session cookie is already
    encrypted; logs and claims are not.

## Risks / Trade-offs

- A provider that omits `code_challenge_methods_supported` and then
  rejects `code_verifier` will fail login under default `auto`.
  → Mitigation: set PKCE mode to Disabled under Settings -> Authentication,
  plus a unit test that `disabled` omits challenge and verifier. Operators
  hit this only on old/broken token endpoints.
- Session cookie grows by ~43 bytes plus the boolean. Encrypted cookie
  budget is already used for `state`/`nonce`.
  → Mitigation: verifier is comparable to existing `state`; no extra
  store.
- Lifting MCP PKCE into a shared module can churn MCP tests.
  → Mitigation: keep `Mcp.OAuth.Pkce.challenge_s256/1` as a delegating
  wrapper if that avoids rewriting MCP tests in this change.

## Migration Plan

- Run the AuthSettings migration (`oidc_pkce_mode` default `auto`) then
  deploy web-ng. Existing rows get Auto. Fresh installs apply the
  committed baseline, then this post-baseline migration. The next login
  sends S256 under Auto. Rolling a pod mid-login still fails the
  in-flight callback the same way a lost session already does
  (`invalid state`).
- Rollback: revert the web-ng image. In-flight PKCE logins fail; users
  retry. Set PKCE to Disabled in Settings if a provider rejects the new
  token request and image rollback is not immediate. The column can stay;
  unused extra varchar is harmless.

## Open Questions

None. Entra Web-app validation is an acceptance task, not an open
product question.
