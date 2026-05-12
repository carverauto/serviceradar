## 1. Plug body-builder support
- [x] 1.1 Add `:json_body_builder` opt to `ServiceRadarWebNGWeb.Plugs.RateLimit`. Takes a 1-arity function `(retry_after :: pos_integer -> iodata)`. When set, the plug uses the function's return value as the 429 body; when unset, the plug keeps the default `{"error":"rate_limited","retry_after":N}`. `:response_mode` interaction: only applies when the chosen mode is `:json`.
- [x] 1.2 Add `:json_body_builder` to `ServiceRadorWebNGWeb.Plugs.LockoutCheck` (0-arity, returns iodata) with the same semantics. Default body stays `{"error":"account_temporarily_locked"}`.
- [x] 1.3 Plug tests: builder-supplied body is used verbatim; default body is unchanged when builder is unset; HTML response mode ignores the builder; init/1 rejects a non-function arity.

## 2. New pipelines
- [x] 2.1 Add `:rate_limit_cli_device` pipeline keyed on bucket `:cli_device_auth`, response mode `:json`, with a body builder that emits the legacy `{"code":429,"error":"rate_limited","message":"Too many authentication attempts. Please try again later."}` shape used by `cli_auth_controller.rate_limited_response/2`.
- [x] 2.2 Decide between editing the existing `:rate_limit_dashboard_publish` pipeline in-place vs adding a successor. (See Design.) Land the chosen approach with the dashboard-specific body builder matching the existing 429 envelope.
- [x] 2.3 Pipeline tests confirm the 429 body matches the existing client contract byte-for-byte.

## 3. CLI device-auth migration
- [x] 3.1 Wire `[:api_token_auth, :rate_limit_cli_device]` onto `POST /api/v1/cli/auth/device` and `POST /api/v1/cli/auth/token`.
- [x] 3.2 Remove `enforce_device_rate_limit/1`, `enforce_token_rate_limit/4`, and `rate_limited_response/2` from `cli_auth_controller.ex`. Update the `device/2` and `token/2` handlers to drop the rate-limit branches from their `with` chains.
- [x] 3.3 Drop the `ServiceRadarWebNGWeb.Auth.RateLimiter` alias.
- [x] 3.4 Update the controller's existing tests to assert the same JSON shape the legacy client expects, plus headers (`retry-after`, `x-ratelimit-*`).

## 4. Dashboard publish migration
- [x] 4.1 Wire the chosen dashboard rate-limit pipeline onto the existing `POST /api/v1/dashboard-packages` scope.
- [x] 4.2 Remove the inline `RateLimiter.check_rate_limit_and_record/3` call in `dashboard_package_publish_controller.ex` and its supporting module attributes / aliases.
- [x] 4.3 Update the existing publish-controller tests to assert the same JSON shape that the `cli dashboard publish` command consumes.

## 5. LiveView pre-render display
- [x] 5.1 In `live/auth_live/local_sign_in.ex`, change the `RateLimiter.check_rate_limit/3` call from the `ServiceRadarWebNGWeb.Auth.RateLimiter` shim to `ServiceRadar.Security.RateLimiter.check/3`. The semantics are identical; this just removes the LiveView's dependency on the shim.

## 6. Shim removal
- [x] 6.1 `grep -r "Auth\.RateLimiter" elixir/web-ng/lib elixir/web-ng/test` returns no hits.
- [x] 6.2 Delete `elixir/web-ng/lib/serviceradar_web_ng_web/auth/rate_limiter.ex`.
- [x] 6.3 Delete `elixir/web-ng/test/phoenix/auth/rate_limiter_test.exs`. The behaviors it covered are now covered by the central `ServiceRadar.Security.RateLimiterTest` and the new plug/pipeline integration tests.

## 7. Docs
- [x] 7.1 Update `docs/PLATFORM_SECURITY_HARDENING.md` operator runbook: cross out the "still on the shim by design" caveat for CLI device-auth and dashboard publish; note that the `Auth.RateLimiter` shim is gone.

## 8. Housekeeping
- [ ] 8.1 Archive the predecessor `migrate-controllers-to-security-pipelines` change once it's no longer in the active list (if not already archived in the parallel audit-history-page change). Predecessor still has open OIDC/SAML wiring + smoke-test items, so this stays open.
