## ADDED Requirements

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
