## 1. Plug response-mode work
- [x] 1.1 Extend `ServiceRadarWebNGWeb.Plugs.RateLimit` with Accept-aware response: `:html_redirect_to`, `:html_flash_template` (with `{retry_after}` placeholder), `:response_mode` (`:auto | :json | :html`) opts. Default `:auto`. Existing JSON path unchanged; HTML path emits a 303 + flash.
- [x] 1.2 Extend `ServiceRadarWebNGWeb.Plugs.LockoutCheck` with the same Accept-aware response (`:response_mode`, `:html_redirect_to`, `:html_flash`); JSON path keeps HTTP 423 `{"error":"account_temporarily_locked"}`.
- [x] 1.3 Plug tests: `:json` mode returns 429 + JSON; `:html` mode emits 303 + flash with `{retry_after}` interpolation; `:auto` mode sniffs `accept: text/html` correctly; init validation rejects unknown `:response_mode`. Redirect target may also be a 0-arity function.

## 2. Config + router scaffolding
- [x] 2.1 Added `:auth_password_reset` (5/300s), `:oauth_password_grant` (10/60s), and `:oauth_client_credentials` (20/60s) to `config :serviceradar_core, ServiceRadar.Security.RateLimiter`.
- [x] 2.2 Added `:rate_limit_password_reset`, `:rate_limit_oauth_password`, and `:rate_limit_oauth_client_credentials` pipelines in `router.ex`. Updated `:rate_limit_auth_local`, `:rate_limit_auth_oidc`, `:rate_limit_auth_saml`, and `:rate_limit_password_reset` to set `response_mode: :auto` with the appropriate `html_redirect_to`. Inlined `LockoutCheck` (actor_id_param `"email"`) into `:rate_limit_auth_local`, and `LockoutCheck` (actor_id_param `"username"`, JSON mode) into `:rate_limit_oauth_password`.

## 3. auth_controller migration (HTML)
- [ ] 3.1 Wire `:rate_limit_auth_local` and the `LockoutCheck` plug (`actor_id_param: "email"`) onto `POST /auth/sign-in` and `POST /auth/local` route scopes.
- [ ] 3.2 Wire `:rate_limit_password_reset` onto the password-reset routes.
- [ ] 3.3 Remove the inline `RateLimiter.check_rate_limit_and_record/3` calls from `auth_controller.ex`'s `create/2`, `local_sign_in/2`, and `request_reset/2`. Remove the pre-auth `Lockouts.active_lockout/1` checks (now handled by `LockoutCheck`). Keep the `Lockouts.record_failed_login/2` calls on credential mismatch.
- [ ] 3.4 Smoke-test: HTML sign-in, rate-limit hit redirects with flash; lockout halts at pipeline level.

## 4. oauth_controller migration (JSON)
- [ ] 4.1 Wire `:rate_limit_oauth_password` + `LockoutCheck` (`actor_id_param: "username"`, `response_mode: :json`) onto the `POST /oauth/token` route's password-grant branch. Wire `:rate_limit_oauth_client_credentials` onto the client_credentials branch.
- [ ] 4.2 Remove inline `RateLimiter.check_rate_limit_and_record/3` and pre-auth lockout checks from `oauth_controller.ex`. Keep `Lockouts.record_failed_login/2` on credential mismatch.
- [ ] 4.3 Smoke-test: invalid grant returns the same JSON shape; rate-limit returns the plug's JSON 429.

## 5. OIDC + SAML callback emissions
- [ ] 5.1 Wire `:rate_limit_auth_oidc` onto `GET /auth/oidc/callback` (no LockoutCheck — there's no actor id to extract pre-validation).
- [ ] 5.2 Wire `:rate_limit_auth_saml` onto `GET /auth/saml/callback`.
- [ ] 5.3 In `oidc_controller.callback/2`, when the ID-token verify or user-lookup fails AND the asserted claims include an `email`, call `Lockouts.record_failed_login(email, %{ip: ..., route: ...})`. Predicate is "the IDP gave us a recognizable identity but the verification didn't accept it" — not transient network errors.
- [ ] 5.4 Same for `saml_controller.consume/2` when the SAML response includes a NameID/email but validation fails.
- [ ] 5.5 Remove the inline `RateLimiter.check_rate_limit_and_record/3` calls from both controllers.

## 6. Shim removal
- [ ] 6.1 `grep -r "Auth.RateLimiter" elixir/web-ng/lib elixir/web-ng/test` returns no hits.
- [ ] 6.2 Delete `elixir/web-ng/lib/serviceradar_web_ng_web/auth/rate_limiter.ex`.
- [ ] 6.3 Remove any aliases / lingering imports.

## 7. Docs
- [ ] 7.1 Update `docs/PLATFORM_SECURITY_HARDENING.md`: drop the "controller migration" step from the rollout list (now complete); replace with a note that all auth routes are pipeline-gated.
- [ ] 7.2 Archive the predecessor change once this lands (`openspec archive add-platform-security-hardening`).
