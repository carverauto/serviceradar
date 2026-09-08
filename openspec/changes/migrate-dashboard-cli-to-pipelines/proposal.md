# Change: Migrate dashboard-publish and CLI device-auth controllers onto the rate-limit pipelines

## Why

`migrate-controllers-to-security-pipelines` (merged) moved every
HTML auth surface and the OAuth `/token` endpoint off the inline
`ServiceRadarWebNGWeb.Auth.RateLimiter` shim and onto the named
`:rate_limit_*` pipelines. Three callers stayed on the shim by
design:

- `ServiceRadarWebNGWeb.CliAuthController` (`/api/v1/cli/auth/device`
  and `/api/v1/cli/auth/token`)
- `ServiceRadarWebNGWeb.DashboardPackagePublishController`
  (`POST /api/v1/dashboard-packages` and its lifecycle siblings)
- `ServiceRadarWebNGWeb.AuthLive.LocalSignIn` (the LiveView's
  pre-render rate-limit *display*, not the credential check —
  that one already migrated)

The reason the first two stayed inline was their JSON 429 shapes
diverge from the plug's default:

- CLI device-auth emits `{"code": 429, "error": "rate_limited", "message": "..."}`
  via `cli_auth_controller.rate_limited_response/2`. Parsed by
  `serviceradar-cli` device-flow clients.
- Dashboard publish has its own per-request JSON envelope with
  fields parsed by the `cli dashboard publish` command.

The plug's default JSON body is
`{"error":"rate_limited","retry_after":N}`. Swapping shapes
would break those clients. This change adds a per-pipeline JSON
body builder so the plug can emit a route-specific shape without
each controller carrying its own inline rate-limit code.

## What Changes

- **ADD** a `:json_body_builder` opt to `ServiceRadarWebNGWeb.Plugs.RateLimit`.
  When set, the plug calls the function with the integer
  `retry_after` and uses its return value (binary or iodata) as
  the response body. Status stays 429. When unset, the plug keeps
  the existing default `{"error":"rate_limited","retry_after":N}`
  body.
- **ADD** the same `:json_body_builder` opt to
  `ServiceRadarWebNGWeb.Plugs.LockoutCheck` (status 423, default
  body `{"error":"account_temporarily_locked"}`).
- **ADD** two new pipelines in `router.ex`:
  - `:rate_limit_cli_device` (bucket `:cli_device_auth`, JSON
    mode, body builder emits the legacy `{code, error, message}`
    shape — `code: 429`, `error: "rate_limited"`,
    `message: "Too many authentication attempts. Please try again
    later."`)
  - `:rate_limit_dashboard_publish_v2` — successor name for the
    existing `:rate_limit_dashboard_publish` pipeline (kept for
    other future use), so this change can wire a different body
    builder without breaking other consumers. (See Open Questions
    for the alternative of editing the existing pipeline in-place.)
- **MODIFY** the routes:
  - `POST /api/v1/cli/auth/device` and `POST /api/v1/cli/auth/token`
    pipe through `[:api_token_auth, :rate_limit_cli_device]`. The
    `rate_limited_response/2` helper inside `cli_auth_controller`
    is removed; both `enforce_device_rate_limit/1` and
    `enforce_token_rate_limit/4` become no-ops or are deleted.
  - The dashboard-package publish routes pipe through
    `[:api_key_auth, :require_dashboard_publish_scope,
    :rate_limit_dashboard_publish_v2]`. The inline
    `RateLimiter.check_rate_limit_and_record/3` call inside
    `dashboard_package_publish_controller` is removed.
- **MODIFY** `ServiceRadarWebNGWeb.AuthLive.LocalSignIn`: keep the
  call to `ServiceRadarWebNGWeb.Auth.RateLimiter.check_rate_limit/3`
  — it's used to *display* whether the user is rate-limited (the
  actual credential check goes through `auth_controller`, which
  already migrated). Switch the call from the shim to the direct
  `ServiceRadar.Security.RateLimiter.check/3` API so the LiveView
  no longer depends on the shim either.
- **REMOVE** `elixir/web-ng/lib/serviceradar_web_ng_web/auth/rate_limiter.ex`
  (the shim) once `grep -r "Auth\.RateLimiter"` in `lib/` and
  `test/` returns zero hits. Tests that exercised the shim move
  to exercising `ServiceRadar.Security.RateLimiter` directly.

## Impact

- Affected specs: `platform-security` (ADDED requirement for the
  body builder; ADDED requirement for the new pipelines).
- Affected code:
  - `elixir/web-ng/lib/serviceradar_web_ng_web/plugs/rate_limit.ex`
  - `elixir/web-ng/lib/serviceradar_web_ng_web/plugs/lockout_check.ex`
  - `elixir/web-ng/lib/serviceradar_web_ng_web/router.ex`
  - `elixir/web-ng/lib/serviceradar_web_ng_web/controllers/cli_auth_controller.ex`
  - `elixir/web-ng/lib/serviceradar_web_ng_web/controllers/dashboard_package_publish_controller.ex`
  - `elixir/web-ng/lib/serviceradar_web_ng_web/live/auth_live/local_sign_in.ex`
  - Tests under `elixir/web-ng/test/phoenix/plugs/`,
    `controllers/cli_auth_controller_test.exs`,
    `controllers/dashboard_package_publish_controller_test.exs`,
    `phoenix/auth/rate_limiter_test.exs` (the last one is deleted
    along with the shim).
  - Deletion: `elixir/web-ng/lib/serviceradar_web_ng_web/auth/rate_limiter.ex`.
- Operational impact:
  - **Bucket rename for in-flight state.** Existing CLI clients at
    the rate limit will get a fresh window at the deploy because
    the bucket key changes from the string `"cli_device_flow"` /
    `"cli_token_exchange"` to the atom `:cli_device_auth`. A
    hostile client at the limit isn't a real user, so the impact
    is fine. Documented in the release notes.
  - **Response body parity verified by tests.** Each route's
    integration test asserts the JSON shape so future plug
    changes can't silently regress the client contract.
- Backwards compatibility: net additive for clients (same JSON
  shape, same status). The shim deletion is internal and only
  affects callers within the repo.
