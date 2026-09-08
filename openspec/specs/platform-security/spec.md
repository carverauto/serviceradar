# platform-security Specification

## Purpose
TBD - created by archiving change add-platform-security-hardening. Update Purpose after archive.
## Requirements
### Requirement: Shared rate-limit substrate

The system SHALL provide a single shared rate-limiter module (`ServiceRadar.Security.RateLimiter`) backed by per-node ETS and coordinated across the BEAM cluster via `ServiceRadar.ProcessRegistry` (the existing Horde-backed registry). The limiter MUST register itself under a node-scoped key and discover peers via Horde rather than introducing a parallel cluster-membership mechanism. Named buckets MUST be configurable per-route with independent window and limit values. Buckets are deployment-wide; tenant isolation is provided by the platform (per-tenant Kubernetes namespace, CNPG schema, and NATS account), so the limiter MUST NOT carry an app-level tenant key. Bucket counters MUST converge across cluster nodes (eventual consistency is acceptable, strict consistency is not required).

#### Scenario: Independent buckets are tracked separately
- **WHEN** two routes are configured with distinct bucket names and both receive traffic from the same client IP
- **THEN** each bucket tracks its own counter and denials in one do not affect the other

#### Scenario: Retry-after is accurate
- **WHEN** a key is denied
- **THEN** the limiter returns the number of seconds until the next slot opens, rounded up to the nearest second

#### Scenario: Counters converge across cluster nodes
- **WHEN** requests for the same bucket+subject key arrive at different web-ng pods in a multi-replica deployment
- **THEN** within the broadcast window the per-pod counters reflect the combined hit rate, and the bucket's limit is enforced cluster-wide rather than per-pod

#### Scenario: A joining node bootstraps state from a peer
- **WHEN** a new web-ng pod joins the cluster
- **THEN** its local ETS table is populated from a peer snapshot so it does not enforce against a cold counter while peers are at-limit

### Requirement: Rate-limit plug for web pipelines

The system SHALL provide `ServiceRadarWebNGWeb.Plugs.RateLimit` that maps a bucket name + subject derivation strategy to the shared limiter. The plug MUST halt the connection with HTTP 429 when denied, MUST set `retry-after` and `x-ratelimit-{limit,remaining,reset}` response headers on every response, and MUST run after session/CSRF plugs so the authenticated actor is attributable.

#### Scenario: Denial halts the pipeline
- **WHEN** a request would exceed its bucket's limit
- **THEN** the plug halts before the controller runs and the response is HTTP 429 with `retry-after` and `x-ratelimit-*` headers

#### Scenario: Allowed request carries informational headers
- **WHEN** a request is allowed
- **THEN** the response includes `x-ratelimit-limit`, `x-ratelimit-remaining`, and `x-ratelimit-reset` headers reflecting the current state

#### Scenario: The pre-existing auth limiter remains a working API
- **WHEN** code calls `ServiceRadarWebNGWeb.Auth.RateLimiter.check_rate_limit/2` or `record_attempt/2`
- **THEN** the call delegates to the shared limiter without changing the caller's contract

### Requirement: Hardened response headers

The system SHALL apply a defense-in-depth response-header policy via `ServiceRadarWebNGWeb.Plugs.SecurityHeaders`. The policy MUST include a Content Security Policy (initially shipped in report-only mode), HSTS when the request scheme is `https`, `Referrer-Policy: strict-origin-when-cross-origin`, a Permissions-Policy that denies camera/microphone/geolocation/payment by default, and `X-Permitted-Cross-Domain-Policies: none`. The CSP MUST be switchable between report-only and enforced via runtime configuration without redeploy. Individual routes MAY opt out of CSP for documented reasons via a plug option.

#### Scenario: Report-only mode emits the header without enforcing
- **WHEN** CSP is configured for report-only
- **THEN** responses include `content-security-policy-report-only` and the page renders without CSP-driven blocking

#### Scenario: Enforce mode blocks violating content
- **WHEN** CSP is flipped to enforce via runtime config
- **THEN** responses include `content-security-policy` and the browser blocks content that violates the directives

#### Scenario: CSP violation reports land in the security event stream
- **WHEN** a browser posts a CSP violation report to `/api/security/csp-report`
- **THEN** a `SecurityEvent` of kind `:csp_violation` is recorded with the violation details

#### Scenario: HTTPS gets HSTS, plain HTTP does not
- **WHEN** the request scheme is `https`
- **THEN** the response includes a `strict-transport-security` header with `max-age` ≥ 6 months
- **AND WHEN** the request scheme is `http`
- **THEN** no `strict-transport-security` header is set (to avoid pinning before TLS is in place)

### Requirement: Upload guard plug

The system SHALL provide `ServiceRadarWebNGWeb.Plugs.UploadGuard` that validates inbound multipart uploads before the controller runs. The guard MUST verify the file's magic-number signature against an allowlist configured per-route, MUST enforce a per-route maximum size, MUST sanitize the original filename by stripping control characters and truncating to 120 characters, and MUST replace the storage filename with a randomized name of the form `{epoch_ms}-{16-byte-base64-random}{ext}`.

#### Scenario: Magic-number mismatch is rejected
- **WHEN** a file is uploaded whose magic-number signature does not match its declared MIME or extension
- **THEN** the plug returns HTTP 415 and the controller does not run

#### Scenario: Over-size upload is rejected
- **WHEN** the upload body exceeds the configured `max_bytes`
- **THEN** the plug returns HTTP 413 and the controller does not run

#### Scenario: Filenames are sanitized
- **WHEN** an upload arrives with a filename containing control characters or longer than 120 characters
- **THEN** the sanitized filename presented to the controller has control characters replaced and the length truncated to 120 characters

### Requirement: Security event stream

The system SHALL provide a `ServiceRadar.Security.SecurityEvent` Ash resource that captures stateless security events. Events MUST include `occurred_at`, `kind`, `severity`, `actor_id` (nullable), `ip`, `route`, structured `details`, and `correlation_id`. The recorder MUST be non-blocking; under sustained overflow it MUST drop events rather than block the request path and MUST increment a telemetry counter. The system SHALL apply a configurable retention TTL (default 90 days) enforced by a scheduled job. Events are deployment-wide; the resource does not carry an app-level tenant key.

#### Scenario: Recording an event is non-blocking
- **WHEN** the recorder is called from a request hot path
- **THEN** the call returns immediately and the event is persisted asynchronously

#### Scenario: Overflow drops events without blocking
- **WHEN** the recorder's bounded queue is full
- **THEN** new events are dropped and a `security.events.dropped` telemetry counter is incremented

#### Scenario: Retention removes expired events
- **WHEN** the retention job runs and finds events older than the configured TTL
- **THEN** those events are deleted and events within the TTL remain

### Requirement: Auth lockout with progressive backoff

The system SHALL provide brute-force lockout on top of the rate limiter. Per-IP buckets that hit their limit MUST escalate through a progressive backoff schedule of `[1m, 5m, 30m, 24h]` before resetting after an hour of inactivity. When failed-login events for a single actor exceed a configured threshold (default 20) within a 1-hour window, the system MUST create a `ServiceRadar.Security.AuthLockout` row that short-circuits subsequent auth attempts for that actor. Unlock MUST require the `:security_admin` capability and MUST emit a `SecurityEvent` of kind `:lockout_cleared`.

#### Scenario: Repeated denials escalate the backoff window
- **WHEN** a key is denied successively without recovery
- **THEN** the denial window grows along the schedule until the maximum is reached

#### Scenario: Cross-IP failed logins lock the actor
- **WHEN** failed-login events for an actor exceed the configured threshold within 1 hour across any combination of source IPs
- **THEN** an `AuthLockout` row is created and subsequent auth attempts for that actor are short-circuited with a generic message

#### Scenario: Unlock requires admin capability
- **WHEN** a user without `:security_admin` attempts to clear a lockout
- **THEN** the action is denied and a `SecurityEvent` of kind `:policy_denied` is recorded
- **AND WHEN** a user with `:security_admin` clears the lockout
- **THEN** the row is updated, a `SecurityEvent` of kind `:lockout_cleared` is recorded, and the actor can authenticate again

### Requirement: Audit RBAC capabilities

The system SHALL define two capabilities for audit and security surfaces: `:audit_viewer` (read access to history, events, and lockouts) and `:security_admin` (mutating actions such as unlock). `:security_admin` MUST imply `:audit_viewer`. Default role mappings SHALL grant `:security_admin` to `:owner` and `:admin`, and `:audit_viewer` to `:operator`.

#### Scenario: Read access is gated by audit_viewer
- **WHEN** a user without `:audit_viewer` requests an audit page
- **THEN** access is denied and a `SecurityEvent` of kind `:policy_denied` is recorded

#### Scenario: Mutating actions require security_admin
- **WHEN** a user with only `:audit_viewer` invokes a mutating action such as unlock
- **THEN** the action is denied and a `SecurityEvent` of kind `:policy_denied` is recorded

### Requirement: Settings → Audit operator surface

The system SHALL provide a Settings → Audit section in the web-ng UI gated by `:audit_viewer` that exposes three sub-pages: **History** (unified AshPaperTrail version timeline across enabled resources with resource-type, actor, action, and time-range filters and a diff view); **Events** (filterable, live-tailable `SecurityEvent` table with filters for kind, severity, actor, ip, route, and time range and CSV export); and **Lockouts** (list of locked accounts with an unlock action gated by `:security_admin`). The system MAY additionally expose a read-only **Rate Limits** panel showing current top-bucket pressure and recent denials.

#### Scenario: History page joins paper trail versions across resources
- **WHEN** an operator opens Settings → Audit → History
- **THEN** the page lists AshPaperTrail versions from every enabled resource in a single timeline, ordered by `inserted_at` descending, with filters that round-trip via the URL

#### Scenario: Events page supports filters and live tail
- **WHEN** an operator opens Settings → Audit → Events
- **THEN** the page renders the most recent events with active filters (kind, severity, actor, ip, route, time range) and subscribes to Phoenix.PubSub so newly recorded events appear at the top without a page refresh

#### Scenario: Unlock is gated by security_admin
- **WHEN** an operator with only `:audit_viewer` opens Settings → Audit → Lockouts
- **THEN** the Unlock control is disabled or hidden
- **AND WHEN** an operator with `:security_admin` clicks Unlock
- **THEN** the lockout is cleared and the operator's user_id is recorded on the AshPaperTrail version

### Requirement: Session cookie hardening

The Phoenix session cookie issued by `ServiceRadarWebNGWeb.Endpoint` MUST be encrypted in addition to signed (i.e., `:encryption_salt` is set so the payload is not readable from the cookie value), MUST be marked `Secure` in any deployment served over HTTPS, MUST be marked `HttpOnly`, and MUST use `SameSite=Strict` for the authenticated session. The encryption secrets MUST be provided via runtime configuration (`config/runtime.exs`) and MUST NOT be hard-coded in the repo.

#### Scenario: Session payload is encrypted, not just signed
- **WHEN** an authenticated session cookie is inspected
- **THEN** the payload is not decodable without the encryption secret (i.e., `Plug.Conn.Cookies.decode/1` plus base64 does not yield the session map)

#### Scenario: HTTPS deployment marks cookie Secure
- **WHEN** the endpoint is served over HTTPS in production
- **THEN** the session cookie carries the `Secure` flag

#### Scenario: Cookie is HttpOnly and Strict SameSite
- **WHEN** the session cookie is set on a response
- **THEN** it carries `HttpOnly` and `SameSite=Strict` attributes

#### Scenario: Existing sessions invalidate cleanly at rollout
- **WHEN** the deployment that enables encryption rolls out
- **THEN** previously issued sign-only cookies fail to decode and the user is redirected to sign in again without crashing the request

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

