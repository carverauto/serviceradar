# Change: Migrate auth/OAuth controllers off inline RateLimiter and onto the named security pipelines

## Why

The `add-platform-security-hardening` change shipped a cluster-aware
`ServiceRadar.Security.RateLimiter`, a `RateLimit` plug, a
`LockoutCheck` plug, and a set of named pipelines in `router.ex`
(`:rate_limit_auth_local`, `:rate_limit_auth_oidc`, etc.). It also
shipped a backwards-compat shim (`ServiceRadarWebNGWeb.Auth.RateLimiter`)
so existing controllers kept working unchanged during the rollout.

Every named pipeline is currently dormant — `pipe_through` never
references any of them. The auth controllers still call
`Auth.RateLimiter.check_rate_limit_and_record/3` inline. Three real
costs follow:

- **Each controller owns its own per-route limits.** Tuning the
  `password_auth` window means editing
  `auth_controller.ex`'s module attributes, not the central
  `config :serviceradar_core, ServiceRadar.Security.RateLimiter`
  bucket map that the platform-security-hardening rollout
  documented as the operator surface.
- **`LockoutCheck` fires nowhere.** It's wired into 2 controllers
  manually (auth + oauth password grant) — every other auth path
  (OIDC, SAML, password reset, OAuth client credentials, CLI
  device auth) lacks a uniform pre-auth lockout check, and the
  ones that have it duplicate the same `Lockouts.active_lockout`
  + redirect pattern in line.
- **The plug can't drive HTML auth routes** as-is. HTML auth
  routes redirect + flash on rate-limit; the plug returns JSON
  429. So even where the pipeline is the right answer, the plug
  can't accept the role without an HTML response mode.

## What Changes

- **ADD** Accept-aware response handling to
  `ServiceRadarWebNGWeb.Plugs.RateLimit`. When the request prefers
  `text/html`, the plug emits a flash + 303 redirect to a
  configurable `:html_redirect_to`. Otherwise it keeps the
  existing JSON 429 behavior. Bucket-specific redirect/flash
  pairs come from plug opts, with sensible defaults.
- **ADD** the same Accept-aware response handling to
  `ServiceRadarWebNGWeb.Plugs.LockoutCheck`.
- **ADD** three new rate-limit buckets to
  `config :serviceradar_core, ServiceRadar.Security.RateLimiter`
  to match the existing inline call sites:
  `:auth_password_reset` (5 per 5 min),
  `:oauth_password_grant` (10/60s),
  `:oauth_client_credentials` (20/60s).
- **ADD** three new pipelines in `router.ex` keyed off those
  buckets: `:rate_limit_password_reset`,
  `:rate_limit_oauth_password`, `:rate_limit_oauth_client_credentials`.
- **MODIFY** the existing auth routes to `pipe_through` the
  appropriate `:rate_limit_*` pipelines and the `LockoutCheck`
  plug where credential paths exist. Remove the inline
  `Auth.RateLimiter.check_rate_limit_and_record/3` calls from
  `auth_controller.ex` and `oauth_controller.ex`. Calling
  `Lockouts.record_failed_login/2` on credential mismatch stays
  in the controller (the controller is the only place that
  *knows* the attempt was a mismatch).
- **MODIFY** the OIDC and SAML callback controllers to call
  `Lockouts.record_failed_login/2` on token-validation /
  ID-token-mapping failure where an actor identifier is
  available from the asserted claims, so cross-IP failed-SSO
  attempts also feed the lockout trigger.
- **REMOVE** `ServiceRadarWebNGWeb.Auth.RateLimiter` (the shim)
  once no callers remain. The new shared limiter lives in
  `ServiceRadar.Security.RateLimiter` and is the only API
  callers should reference.

## Impact

- Affected specs: `platform-security` (ADDED requirements; no
  semantic changes to existing requirements).
- Affected code:
  - `elixir/web-ng/lib/serviceradar_web_ng_web/plugs/rate_limit.ex`
    (Accept-aware response)
  - `elixir/web-ng/lib/serviceradar_web_ng_web/plugs/lockout_check.ex`
    (Accept-aware response)
  - `elixir/web-ng/lib/serviceradar_web_ng_web/router.ex` (new
    pipelines + wiring)
  - `elixir/web-ng/lib/serviceradar_web_ng_web/controllers/auth_controller.ex`
    (remove inline limiter calls)
  - `elixir/web-ng/lib/serviceradar_web_ng_web/controllers/oauth_controller.ex`
    (remove inline limiter calls)
  - `elixir/web-ng/lib/serviceradar_web_ng_web/controllers/oidc_controller.ex`
    (add `record_failed_login` on validation failure)
  - `elixir/web-ng/lib/serviceradar_web_ng_web/controllers/saml_controller.ex`
    (same)
  - `elixir/serviceradar_core/config/config.exs` (new bucket
    entries)
  - Deletion: `elixir/web-ng/lib/serviceradar_web_ng_web/auth/rate_limiter.ex`
    (after the final caller is removed)
- Operational impact:
  - One-time bucket-rename: existing in-flight rate-limit state
    in the `"password_auth"`, `"local_auth"`, `"oidc_callback"`,
    `"saml_consume"`, `"oauth_password_grant"`,
    `"oauth_client_credentials"`, `"password_reset"` buckets
    will not roll forward into the new atom-keyed buckets. Any
    actor at-limit gets a fresh window at the deploy. No user
    visible effect.
  - CLI device-auth (`cli_auth_controller`) is **out of scope**
    for this change: its existing JSON 429 shape is
    `{code, error, message}`, which CLI clients parse. Aligning
    to the plug's `{error, retry_after}` shape would break those
    clients. Either accept the divergence as documented, or
    extend the plug with controller-supplied response bodies in
    a follow-up.
- Backwards compatibility: the `Auth.RateLimiter` shim's public
  functions (`check_rate_limit/3`, `record_attempt/2`,
  `check_rate_limit_and_record/3`, `clear_rate_limit/2`) remain
  callable until the final controller is migrated. The deletion
  is the last step.
