## RENAMED Requirements

- FROM: `### Requirement: OIDC and SAML record failed identity assertions`
- TO: `### Requirement: OIDC records failed identity assertions`

## MODIFIED Requirements

### Requirement: Pipeline-attached rate-limiting on auth surfaces

Every authenticated-credential surface in web-ng MUST gate
inbound requests through the appropriate named rate-limit
pipeline in `router.ex` rather than via an inline
`Auth.RateLimiter.check_rate_limit_and_record/3` call inside the
controller. The pipelines and the routes they MUST cover:

- `:rate_limit_auth_local` — `POST /auth/sign-in`, `POST /auth/local`
- `:rate_limit_password_reset` — password reset request + reset routes
- `:rate_limit_auth_oidc` — `GET /auth/oidc/callback`
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

### Requirement: OIDC records failed identity assertions

The system SHALL feed cross-IP failed-SSO attempts into the same lockout trigger as local password failures. When `oidc_controller.callback/2` extracts a recognizable actor identifier (email) from the asserted claims and the verification or user-lookup subsequently fails for an identity-validation reason (signature mismatch, audience mismatch, missing required claim, user record not found), the controller MUST call `ServiceRadar.Security.Lockouts.record_failed_login(actor_id, %{ip, route})`. Transient errors (IDP unreachable, network failure, malformed response) MUST NOT trigger the record path.

#### Scenario: Verified-identity, failed-validation triggers record_failed_login
- **WHEN** the IDP returns a signed ID token whose `email` claim
  refers to a known user but the signature verification fails
- **THEN** `Lockouts.record_failed_login(email, …)` is called and
  a `:login_failed` SecurityEvent is recorded

#### Scenario: Transient IDP failure does not feed lockouts
- **WHEN** the OIDC discovery URL is unreachable and the callback
  errors before any claim is parsed
- **THEN** `Lockouts.record_failed_login` is not called
