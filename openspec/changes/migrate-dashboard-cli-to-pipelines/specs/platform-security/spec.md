## ADDED Requirements

### Requirement: Pipeline-configurable JSON response body for rate-limit and lockout denials

The system SHALL allow each rate-limit / lockout pipeline to emit a route-specific JSON body on denial without forcing each controller to handle the rate-limit response inline. `ServiceRadarWebNGWeb.Plugs.RateLimit` MUST accept an optional `:json_body_builder` opt that is a 1-arity function (`(retry_after :: pos_integer) -> iodata`). `ServiceRadarWebNGWeb.Plugs.LockoutCheck` MUST accept the same opt as a 0-arity function. When unset, both plugs MUST keep their existing default bodies. The opt only applies when the chosen response mode is `:json`; HTML mode renders the flash + redirect regardless.

#### Scenario: Builder-supplied body is used verbatim
- **WHEN** a pipeline is configured with `json_body_builder: fn ra -> ~s({"code":429,"retry":#{ra}}) end` and the request is denied
- **THEN** the response body is exactly `{"code":429,"retry":<retry_after>}`

#### Scenario: Unset builder keeps the default body
- **WHEN** no `:json_body_builder` is configured
- **THEN** the response body is `{"error":"rate_limited","retry_after":<retry_after>}` for `RateLimit` and `{"error":"account_temporarily_locked"}` for `LockoutCheck`

#### Scenario: HTML mode ignores the builder
- **WHEN** the resolved response mode is `:html`
- **THEN** the plug emits the configured 303 redirect + flash, not a JSON body

### Requirement: CLI device-auth and dashboard publish routes are pipeline-gated

The system SHALL gate the CLI device-auth endpoints (`POST /api/v1/cli/auth/device`, `POST /api/v1/cli/auth/token`) and the dashboard package publish endpoints (`POST /api/v1/dashboard-packages` and its lifecycle siblings) through their respective rate-limit pipelines rather than inline `Auth.RateLimiter.check_rate_limit_and_record/3` calls. The pipelines MUST emit each route's existing 429 JSON shape via `:json_body_builder` so currently-deployed CLI clients keep parsing the response without changes.

#### Scenario: CLI device-auth 429 retains its legacy shape
- **WHEN** a CLI client exceeds the `:cli_device_auth` bucket on `POST /api/v1/cli/auth/device`
- **THEN** the 429 response body is `{"code":429,"error":"rate_limited","message":"Too many authentication attempts. Please try again later."}` (the shape the existing CLI client parses)

#### Scenario: Dashboard publish 429 retains its existing shape
- **WHEN** a CLI client exceeds the dashboard publish bucket on `POST /api/v1/dashboard-packages`
- **THEN** the 429 response body matches the shape currently emitted by `dashboard_package_publish_controller`'s inline rate-limit handler

### Requirement: ServiceRadarWebNGWeb.Auth.RateLimiter shim is removed

The system SHALL delete `elixir/web-ng/lib/serviceradar_web_ng_web/auth/rate_limiter.ex` and its test once the CLI, dashboard publish, and LiveView pre-render callers no longer reference it. After this change, `grep -r "Auth\\.RateLimiter" elixir/web-ng/lib elixir/web-ng/test` MUST return zero hits. Callers reach the cluster-aware limiter through `ServiceRadar.Security.RateLimiter` directly (for non-plug use such as the LiveView display) or through `ServiceRadarWebNGWeb.Plugs.RateLimit` (for HTTP routes).

#### Scenario: A fresh grep for the shim returns empty
- **WHEN** the change is complete
- **THEN** `grep -r "Auth\\.RateLimiter" elixir/web-ng/lib elixir/web-ng/test` matches no files
