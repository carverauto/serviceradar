## Why

The dashboard authoring loop ends at `serviceradar-cli dashboard build`. The CLI then calls `POST /api/v1/dashboard-packages` (multipart manifest + renderer + route) and `POST /api/v1/dashboard-packages/:id/enable` to flip the package live, but **neither endpoint exists** in `web-ng`. The router only ships the asset-serving routes (`GET /api/v1/dashboard-packages/:id/renderer{,.wasm}`) and a Settings LiveView upload UI at `/settings/dashboards/packages/new`. So today every dashboard author has to:

1. Build locally,
2. Open the Settings UI in a browser,
3. Click through the upload modal,
4. Click Enable + bind a route,

which defeats the purpose of having a CLI auth flow that already mints scoped JWTs (`scopes: ["dashboard.publish"]`) via the cli-device-auth proposal.

The server-side primitives needed for an API publish path **already exist** in `ServiceRadarWebNG.Dashboards.Packages` (`import_json/3`, `enable/2`, `disable/2`, `set_default_instance/2`), `ServiceRadar.Dashboards.DashboardPackage` (Ash `:upsert` keyed on `unique_dashboard_version`), and `ServiceRadarWebNG.Plugins.Storage` (50 MB blob caps, SHA256 verification). What's missing is the HTTP surface that wires the CLI's existing requests into those primitives, plus the RBAC + route-slug-ownership rules that make it safe to expose to any user with a publish-scoped JWT — not just admins clicking through a LiveView.

## What Changes

- **New API endpoints**, both gated on `cli.dashboard.publish` (RBAC permission) **AND** the bearer token's `dashboard.publish` scope claim (defense in depth):
  - `POST /api/v1/dashboard-packages` — multipart upload (`manifest` JSON, `renderer` JS/WASM, `route` slug field). Wraps `Packages.import_json/3` plus, when `route` is present, a `DashboardInstance` upsert that binds the slug to the published package. Returns `{id, dashboard_id, version, route_slug, status, content_hash}` so the CLI can compose the enable URL deterministically.
  - `POST /api/v1/dashboard-packages/:id/enable` — JSON `{route?}`. Flips the package to `:enabled`, optionally rebinds the named slug to it. Idempotent: a noop on an already-enabled package whose route already binds that slug.
  - `POST /api/v1/dashboard-packages/:id/disable` — JSON. Flips the package to `:disabled` (does NOT delete instances or content; matches the existing LiveView semantics). Symmetric so the CLI has a clean rollback path.
- **New RBAC permissions** in `ServiceRadar.Identity.RBAC` catalog under a `dashboards` section:
  - `cli.dashboard.publish` — required to upload a new package version via the API. Default: admin role only.
  - `cli.dashboard.enable` — required to flip a package live and to (re)bind a route slug. Default: admin role only.
  - `cli.dashboard.disable` — required to flip a package back to `:disabled`. Default: admin role only.

  These three are deliberately separate from the LiveView-side `plugins.{view,stage,approve,assign}` permissions so the API path can be granted without granting the full plugin-administration UI surface.
- **Token-scope plug** at `ServiceRadarWebNGWeb.Plugs.RequireOauthScope` — wraps `oauth_token_scope` (already populated by `Plugs.ApiAuth`) and rejects the request with a 403 if the bearer token's `scopes` claim does not include the required scope. The publish/enable/disable routes use `plug RequireOauthScope, scope: "dashboard.publish"`.
- **Route-slug ownership rule** in `Packages.import_json/3` (or a sibling `Packages.publish_with_route/4`): when a `route_slug` is requested, the server SHALL refuse the publish if any **enabled** `DashboardInstance` row already binds that slug to a package whose `dashboard_id` differs from the manifest's `id`. The CLI receives a structured 409 with the conflicting `dashboard_id` so the author can pick a fresh slug or rename their package.
- **Version-overwrite rule**: `DashboardPackage.upsert` is keyed on `unique_dashboard_version`, so the *same* `dashboard_id@version` can be re-pushed. The new endpoint SHALL refuse to overwrite an enabled package's bytes unless the new manifest's `renderer.sha256` matches the existing `content_hash` (true idempotency). To replace bytes, the author must bump `manifest.version` or first call disable.
- **Multipart hardening** at the controller layer:
  - `manifest` part SHALL be `application/json`, ≤ 256 KB.
  - `renderer` part SHALL be `application/javascript`, `application/wasm`, or `text/javascript`, ≤ `Storage.max_upload_bytes()` (50 MB default).
  - The `route` form field SHALL match a `^[a-z0-9][a-z0-9-]{1,62}$` slug regex; the controller SHALL reject anything else with a structured 400 (no DB writes attempted).
  - Reject the request with 413 (content-too-large) before any blob is buffered when either part exceeds its cap, using Plug's `:length` enforcement.
- **Per-IP + per-token rate limit**: 10 publish attempts/minute/token (matches the cli-device-auth `device` endpoint cadence). Returns 429 with `Retry-After` when exceeded.
- **Audit-log row** written to the existing `ServiceRadarWebNG.Audit` sink on every publish/enable/disable, capturing `{actor_user_id, jti, dashboard_id, version, route_slug, content_hash, action}`. The cli-device-auth `CliSession` row stamps `last_used_at` on the same hop.
- **CLI publish.ts**: align response parsing with the new contract (already calls these endpoints with the right shape; only minor adjustments for the structured 409 / 413 / 429 error envelopes).
- **Integration tests** under `elixir/web-ng/test/phoenix/` (`:integration` tag, srql-fixtures CNPG instance) covering: happy publish, scope-missing JWT → 403, RBAC-missing user → 403, slug-conflict → 409, version-overwrite-with-different-bytes → 409, oversized manifest → 413, oversized renderer → 413, rate limit → 429, full publish → enable → asset GET round-trip, idempotent re-publish.

## Impact

- **Affected specs**: NEW capability `dashboard-package-publish-api`. No existing capability covers this surface.
- **Affected code**:
  - `elixir/web-ng/lib/serviceradar_web_ng_web/router.ex` — new `scope "/api/v1"` block + 3 routes under `:api_key_auth` pipeline.
  - `elixir/web-ng/lib/serviceradar_web_ng_web/controllers/dashboard_package_publish_controller.ex` — new file; thin Plug.Conn → `Packages.import_json/3` adapter.
  - `elixir/web-ng/lib/serviceradar_web_ng_web/plugs/require_oauth_scope.ex` — new file; reusable scope-gate plug.
  - `elixir/web-ng/lib/serviceradar_web_ng/dashboards/packages.ex` — extend `import_json/3` (or add `publish/3`) with route-slug ownership and version-overwrite checks. Add `bind_route/3` helper.
  - `elixir/serviceradar_core/lib/serviceradar/identity/rbac/catalog.ex` — three new permissions in a new `dashboards` section.
  - `elixir/web-ng/lib/serviceradar_web_ng/auth/cli_sessions.ex` — bump `last_used_at` on publish hop (reuses existing `record_use` action).
  - `js/cli/src/dashboard/publish.ts` — surface 409/413/429 structured errors; print actionable hint per error.
  - `elixir/web-ng/test/phoenix/controllers/dashboard_package_publish_controller_test.exs` — new file, 12+ cases.
- **Affected proposals**: `add-cli-device-auth` ships the JWT + `dashboard.publish` scope this proposal consumes; both proposals must be live for the end-to-end CLI flow to work. Neither blocks the other at archive time — this proposal can land independently and the CLI continues to fall back to the manual-token paste when the device-auth flow isn't available.
- **Backwards compatibility**: the existing LiveView upload at `/settings/dashboards/packages/new` is untouched — it still calls `Packages.import_json/3` directly (session-auth path). The new API path adds a second entry point with the additional checks above; the LiveView path SHALL also pick up the route-slug-ownership and version-overwrite rules so the two paths cannot diverge.
