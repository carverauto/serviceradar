## ADDED Requirements

### Requirement: Accept-aware response from rate-limit and lockout plugs

The system SHALL allow `ServiceRadarWebNGWeb.Plugs.RateLimit` and `ServiceRadarWebNGWeb.Plugs.LockoutCheck` to serve both HTML and JSON callers from the same pipeline. Each plug MUST honor the request's `accept` header (or a per-plug `response_mode` override) so HTML clients receive a 303 redirect + Phoenix flash while JSON clients receive HTTP 429 / 423 with the existing JSON body. The `SecurityEvent` recorded on denial MUST be the same regardless of response mode.

#### Scenario: HTML route gets a flash + redirect
- **WHEN** a route is configured with `response_mode: :html` (or
  `:auto` and the request prefers `text/html`) and the rate limit
  is hit
- **THEN** the plug responds with HTTP 303, sets a flash on the
  conn, and redirects to the configured `:html_redirect_to`

#### Scenario: JSON route gets the existing 429 body
- **WHEN** a route is configured with `response_mode: :json` (or
  `:auto` with no `text/html` in `accept`)
- **THEN** the plug responds with HTTP 429 and the body
  `{"error":"rate_limited","retry_after":N}` and sets the
  `retry-after` + `x-ratelimit-*` headers

#### Scenario: Locked actor on an HTML route gets a flash + redirect
- **WHEN** a request hits a route with the `LockoutCheck` plug in
  HTML mode and `active_lockout/1` returns a row for the actor
- **THEN** the plug responds with HTTP 303 + flash, redirecting to
  the configured sign-in path

### Requirement: Pipeline-attached rate-limiting on auth surfaces

Every authenticated-credential surface in web-ng MUST gate
inbound requests through the appropriate named rate-limit
pipeline in `router.ex` rather than via an inline
`Auth.RateLimiter.check_rate_limit_and_record/3` call inside the
controller. The pipelines and the routes they MUST cover:

- `:rate_limit_auth_local` — `POST /auth/sign-in`, `POST /auth/local`
- `:rate_limit_password_reset` — password reset request + reset routes
- `:rate_limit_auth_oidc` — `GET /auth/oidc/callback`
- `:rate_limit_auth_saml` — `GET /auth/saml/callback`
- `:rate_limit_oauth_password` — `POST /oauth/token` (password grant)
- `:rate_limit_oauth_client_credentials` — `POST /oauth/token` (client credentials)

The CLI device-auth endpoints (`/api/v1/cli/auth/*`) are
**excluded** from this requirement because their existing 429 JSON
shape is consumed by CLI clients that parse the legacy
`{code, error, message}` format. Aligning that shape is a
separate change.

#### Scenario: Inline limiter call is removed alongside pipeline wiring
- **WHEN** a controller is migrated to a named rate-limit pipeline
- **THEN** the inline `Auth.RateLimiter.check_rate_limit_and_record/3`
  call for that route is removed in the same commit so requests
  pass through exactly one rate-limit check

#### Scenario: LockoutCheck is wired onto password-credential pipelines
- **WHEN** a route accepts a password credential subject to
  brute-force (auth_local, oauth_password)
- **THEN** the request pipeline includes `LockoutCheck` with the
  appropriate `actor_id_param` so locked actors are short-circuited
  at the pipeline boundary

### Requirement: OIDC and SAML record failed identity assertions

The system SHALL feed cross-IP failed-SSO attempts into the same lockout trigger as local password failures. When `oidc_controller.callback/2` or `saml_controller.consume/2` extracts a recognizable actor identifier (email / NameID) from the asserted claims and the verification or user-lookup subsequently fails for an identity-validation reason (signature mismatch, audience mismatch, missing required claim, user record not found), the controller MUST call `ServiceRadar.Security.Lockouts.record_failed_login(actor_id, %{ip, route})`. Transient errors (IDP unreachable, network failure, malformed response) MUST NOT trigger the record path.

#### Scenario: Verified-identity, failed-validation triggers record_failed_login
- **WHEN** the IDP returns a signed ID token whose `email` claim
  refers to a known user but the signature verification fails
- **THEN** `Lockouts.record_failed_login(email, …)` is called and
  a `:login_failed` SecurityEvent is recorded

#### Scenario: Transient IDP failure does not feed lockouts
- **WHEN** the OIDC discovery URL is unreachable and the callback
  errors before any claim is parsed
- **THEN** `Lockouts.record_failed_login` is not called

## MODIFIED Requirements

### Requirement: Plug pipeline ordering

The web-ng router and endpoint pipelines SHALL apply security plugs in the following order so that subject attribution and short-circuiting work correctly: `accepts` → `fetch_session` (browser) → `protect_from_forgery` (browser) → `SecurityHeaders` → `RateLimit` → `LockoutCheck` (where credential paths exist) → route-specific plugs (`UploadGuard`). New web routes that accept user-supplied payloads MUST opt into a named rate-limit bucket; routes that accept binary uploads MUST opt into `UploadGuard`; routes that accept credentials MUST opt into the `LockoutCheck` plug with an appropriate `:actor_id_param` or `:actor_id_assign`.

#### Scenario: SecurityHeaders runs before any controller writes a response
- **WHEN** a controller writes a response on any pipeline that includes SecurityHeaders
- **THEN** the response carries the configured security headers

#### Scenario: RateLimit halts before controller work
- **WHEN** RateLimit denies a request
- **THEN** the controller body does not execute and no downstream Ash actions are invoked

#### Scenario: LockoutCheck halts before the credential check runs
- **WHEN** a request hits a credential route, the actor is currently locked, and `LockoutCheck` is wired into the pipeline
- **THEN** the controller does not see the request and the response is the configured locked-account message (HTTP 423 JSON or 303 HTML redirect, depending on Accept)
