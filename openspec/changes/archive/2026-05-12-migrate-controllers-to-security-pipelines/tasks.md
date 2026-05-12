## 1. Plug response-mode work
- [x] 1.1 Extend `ServiceRadarWebNGWeb.Plugs.RateLimit` with Accept-aware response: `:html_redirect_to`, `:html_flash_template` (with `{retry_after}` placeholder), `:response_mode` (`:auto | :json | :html`) opts. Default `:auto`. Existing JSON path unchanged; HTML path emits a 303 + flash.
- [x] 1.2 Extend `ServiceRadarWebNGWeb.Plugs.LockoutCheck` with the same Accept-aware response (`:response_mode`, `:html_redirect_to`, `:html_flash`); JSON path keeps HTTP 423 `{"error":"account_temporarily_locked"}`.
- [x] 1.3 Plug tests: `:json` mode returns 429 + JSON; `:html` mode emits 303 + flash with `{retry_after}` interpolation; `:auto` mode sniffs `accept: text/html` correctly; init validation rejects unknown `:response_mode`. Redirect target may also be a 0-arity function.

## 2. Config + router scaffolding
- [x] 2.1 Added `:auth_password_reset` (5/300s), `:oauth_password_grant` (10/60s), and `:oauth_client_credentials` (20/60s) to `config :serviceradar_core, ServiceRadar.Security.RateLimiter`.
- [x] 2.2 Added `:rate_limit_password_reset`, `:rate_limit_oauth_password`, and `:rate_limit_oauth_client_credentials` pipelines in `router.ex`. Updated `:rate_limit_auth_local`, `:rate_limit_auth_oidc`, `:rate_limit_auth_saml`, and `:rate_limit_password_reset` to set `response_mode: :auto` with the appropriate `html_redirect_to`. Inlined `LockoutCheck` (actor_id_param `"email"`) into `:rate_limit_auth_local`, and `LockoutCheck` (actor_id_param `"username"`, JSON mode) into `:rate_limit_oauth_password`.

## 3. auth_controller migration (HTML)
- [x] 3.1 Split the `/auth` scope: `POST /auth/sign-in` and `POST /auth/local/sign-in` moved into a sub-scope piped through `[:browser, :rate_limit_auth_local]`. The pipeline plug already inlines `LockoutCheck` on `"email"`.
- [x] 3.2 Password-reset submissions (`POST /auth/password-reset`, `PUT /auth/password-reset/:token`) moved into a sub-scope piped through `[:browser, :rate_limit_password_reset]`. Form-render GETs (`new_reset_request`, `show_reset_form`) stay unmetered.
- [x] 3.3 Removed inline `RateLimiter.check_rate_limit_and_record/3` calls and pre-auth `Lockouts.active_lockout/1` checks from `auth_controller.ex`'s `create/2`, `local_sign_in/2`, and `request_reset/2`. `Lockouts.record_failed_login/2` remains on credential-mismatch branches. Dropped now-unused `Auth.RateLimiter` alias and the four `@password_*` module attributes.
- [x] 3.4 Smoke-test HTML sign-in end-to-end against a running stack — deferred to operator-side validation after the staging deploy of #3276; plug unit tests for the response-mode branches cover the request-shape side.

## 4. oauth_controller migration (JSON)
- [x] 4.1 The `/oauth/token` endpoint is multiplexed by `grant_type` (password vs. client_credentials), so pipeline-level rate-limiting can't differentiate the two buckets. Resolution: the inline call sites in `oauth_controller.ex` switch from `ServiceRadarWebNGWeb.Auth.RateLimiter` (the shim) to `ServiceRadar.Security.RateLimiter` (direct), using atom bucket names. The pipeline definitions `:rate_limit_oauth_password` and `:rate_limit_oauth_client_credentials` from section 2 remain available for any future split-endpoint design.
- [x] 4.2 Removed the controller-owned `@password_grant_*` / `@client_credentials_*` constants; limits now come from the central bucket config. Existing `Lockouts.active_lockout/1` pre-check and `Lockouts.record_failed_login/2` on credential mismatch already in place from earlier work — kept as-is.
- [x] 4.3 Smoke-test invalid grant + rate-limit responses against a running stack — deferred to operator-side validation after the staging deploy of #3276.

## 5. OIDC + SAML callback emissions
- [x] 5.1 `GET /auth/oidc/callback` already routed through `[:browser, :rate_limit_auth_oidc]` (section 3).
- [x] 5.2 `POST /auth/saml/consume` already routed through `[:browser, :rate_limit_auth_saml]` (section 3).
- [x] 5.3 `oidc_controller.handle_code_exchange/3` split into `exchange_and_verify` (failures here do NOT feed lockouts — we don't have a verified identity yet) and `complete_oidc_login` (failures here DO call `Lockouts.record_failed_login(claims["email"], …)` since the ID token verified before the failure). Removed the inline `check_rate_limit` plug and helper.
- [x] 5.4 `saml_controller.handle_successful_assertion/3` now passes the validated `user_info` to a `record_validated_failure/3` helper that calls `Lockouts.record_failed_login(user_info.email, …)` on `:unsafe_account_linking` and `:user_provisioning_failed`. Removed the inline `check_rate_limit` plug and helper.
- [x] 5.5 Removed inline `RateLimiter.check_rate_limit_and_record/3` calls from both controllers; dropped the per-controller `@callback_rate_*` constants and the `Auth.RateLimiter` aliases.

## 6. Shim removal — handled in successor change
The four callers still using `ServiceRadarWebNGWeb.Auth.RateLimiter` after sections 3–5 were:

- `controllers/cli_auth_controller.ex` (explicit non-goal of this change: legacy 429 JSON shape, see proposal §non-goals)
- `controllers/dashboard_package_publish_controller.ex` (out of the auth migration scope)
- `live/auth_live/local_sign_in.ex` (LiveView pre-render rate-limit display)
- The test files that exercise the shim or those call sites

Successor change `migrate-dashboard-cli-to-pipelines` (merged via #3280) migrated all four and deleted the shim. Nothing references `ServiceRadarWebNGWeb.Auth.RateLimiter` anymore.

## 7. Docs
- [x] 7.1 `docs/PLATFORM_SECURITY_HARDENING.md` rollout step 7 updated: replaced the open "controller migration" bullet with a record of what was migrated, what stays on the shim by design (CLI device-auth, dashboard publish, local_sign_in LiveView pre-render), and the OIDC/SAML lockout-feeding behavior.
- [x] 7.2 Predecessor change `add-platform-security-hardening` already archived to `openspec/changes/archive/2026-05-12-add-platform-security-hardening/` and its capability materialized into `openspec/specs/platform-security/spec.md` (done at branch creation).
