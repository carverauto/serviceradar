## 1. Shared S256 helper

- [x] 1.1 Add `ServiceRadarWebNG.Pkce` with `generate_verifier/0` (32-byte
      CSPRNG, base64url without padding, length 43) and `challenge_s256/1`
      (SHA-256 then base64url without padding). Never implement `plain`.
- [x] 1.2 Point `ServiceRadarWebNG.Mcp.OAuth.Pkce.challenge_s256/1` at the
      shared helper (wrapper is fine). MCP authorize/token behavior stays
      unchanged.
- [x] 1.3 Unit-test verifier charset/length and that `challenge_s256/1`
      matches the RFC 7636 appendix B vector
      (`dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk` →
      `E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM`).

## 2. Authorize and token exchange

- [x] 2.1 Add `AuthSettings.oidc_pkce_mode` (`:auto` | `:required` |
      `:disabled`, default `:auto`) and a platform migration. Surface it
      on **Settings -> Authentication** as OIDC PKCE radios (Auto /
      Required / Disabled). Do not patch `platform_schema.sql`; the
      baseline marker is older than this migration.
- [x] 2.2 Teach `OIDCClient.authorize_url/1` to decide PKCE from mode +
      discovery `code_challenge_methods_supported`:
      - `auto` + (S256 advertised or methods absent) → include
        `code_challenge` and `code_challenge_method=S256`
      - `auto` + methods present without S256 → omit PKCE, log a warning,
        never send `plain`
      - `required` + methods present without S256 → `{:error, :pkce_s256_unsupported}`
      - `disabled` → omit PKCE
- [x] 2.3 Return the verifier (and whether PKCE was used) with `state` and
      `nonce`. Do not put the verifier on the authorize URL.
- [x] 2.4 Teach `OIDCClient.exchange_code/2` to send `code_verifier` in the
      form body when provided, **and** keep `client_secret`. Omit
      `code_verifier` when PKCE was not used.
- [x] 2.5 Do not log the verifier or the token-request form body.

## 3. Callback session binding

- [x] 3.1 `OIDCController.request/2` stores `:oidc_state`, `:oidc_nonce`,
      `:oidc_code_verifier`, and `:oidc_pkce` in session.
- [x] 3.2 Every callback clause deletes those four keys **before**
      `exchange_code/2` (success, IdP error, and invalid-state paths).
- [x] 3.3 After consume: invalid `state` still fails as today. If
      `:oidc_pkce` was true and the verifier is missing/empty, fail with
      a generic auth error and **do not** call the token endpoint.
- [x] 3.4 Pass the consumed verifier into `exchange_code/2` only on the
      PKCE path. Leave `nonce` verification unchanged.
- [x] 3.5 Update the Endpoint session comment so `:oidc_code_verifier` is
      listed next to `:oidc_state` / `:oidc_nonce` (SameSite=Lax still
      required for the IdP top-level GET).

## 4. Tests

- [x] 4.1 `oidc_client_test.exs`: authorize URL includes S256 challenge
      when discovery advertises S256; includes S256 when methods are
      absent under `auto`; omits PKCE when methods omit S256; `required`
      errors when S256 is missing; `disabled` omits PKCE. Challenge
      matches `Pkce.challenge_s256(verifier)`.
- [x] 4.2 `oidc_client_test.exs`: token exchange form includes
      `code_verifier` and `client_secret` on the PKCE path, and omits
      `code_verifier` when PKCE was not used. Outbound-policy rejection
      of the token endpoint still holds.
- [x] 4.3 `oidc_controller_test.exs`: missing session still rejects;
      PKCE login with missing/empty verifier after a matching `state`
      does not call `exchange_code/2`; replay of the same callback after
      consume fails; session keys are gone after callback; existing
      state/nonce failure flash stays the same.
- [x] 4.4 Existing OIDC and MCP PKCE tests still pass.

## 5. Docs and Entra check

- [x] 5.1 Document upstream PKCE in `docs/docs/auth-configuration.md`
      (S256, confidential client still uses the secret, Settings UI
      modes, `disabled` escape hatch). Explicitly distinguish MCP OAuth
      PKCE (`/oauth/authorize`) from this login-client PKCE.
- [ ] 5.2 Validate the flow against a Microsoft Entra Web application
      registration (authorize includes S256, token exchange accepts
      verifier + secret, login completes). Record the result on
      issue #4256.
