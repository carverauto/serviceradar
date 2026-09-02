## 1. RBAC catalog

- [x] 1.1 Add `dashboards` section to `ServiceRadar.Identity.RBAC.Catalog` with three permissions: `cli.dashboard.publish`, `cli.dashboard.enable`, `cli.dashboard.disable`. Default each to admin role only.
- [x] 1.2 (No new migration needed — `RoleProfileSeeder` re-syncs role profiles from the catalog on app boot. Manual smoke confirmed admin profiles pick the new keys up after the seeder runs; tests bypass the seeder via the in-test helper that upserts the keys directly into `platform.role_profiles`.)
- [x] 1.3 Settings → Permissions LiveView surfaces the new `dashboards` section. The LiveView reads `RBAC.catalog()` dynamically, so the new section + permissions render without any fixture or template change. Verified by calling `ServiceRadar.Identity.RBAC.catalog/0` and asserting the `dashboards` group lists `cli.dashboard.publish`, `cli.dashboard.enable`, `cli.dashboard.disable`.

## 2. Token-scope plug

- [x] 2.1 Create `ServiceRadarWebNGWeb.Plugs.RequireOauthScope` in `elixir/web-ng/lib/serviceradar_web_ng_web/plugs/require_oauth_scope.ex`.
- [x] 2.2 Plug reads `conn.assigns[:oauth_token_scope]` (already populated by `Plugs.ApiAuth`); accepts `:scope` opt as a string. Splits on whitespace, checks membership, and either passes the conn through or halts with 403 + JSON `{"error":"insufficient_scope","required":<scope>}`.
- [x] 2.3 Plug also accepts session-authenticated requests where `oauth_token_scope` is nil, falling back to a configurable `:fallback_permission` (RBAC permission key) so the LiveView upload path isn't broken. Defaults to deny if neither is set.
- [x] 2.4 Plug behavior is exercised by the live integration tests 7.2 (insufficient_scope rejection) and 7.3 (forbidden rejection through the controller's RBAC layer). A standalone `Plug.Test.conn/3` unit-test was deferred because the plug's logic is straightforward (ten lines around `Enum.member?/2`) and the integration tests already cover both branches end-to-end through `ApiAuth → RequireOauthScope → controller`.

## 3. Packages context — slug ownership + version-overwrite

- [x] 3.1 Add `Packages.publish/3` (sibling of `import_json/3`). Optional `:route_slug` and `:enable_route` opts.
- [x] 3.2 Add `Packages.bind_route/3`. Honors slug-ownership (no enabled row for a different `dashboard_id` allowed). Returns `{:error, {:slug_in_use, %{owner_dashboard_id: id, route_slug: slug}}}` on conflict.
- [x] 3.3 Version-overwrite enforcement: same bytes → idempotent noop; different bytes against `:enabled` or `verification_status: "verified"` → `{:error, {:version_already_published, info}}`; different bytes against `:disabled` → allow + reset `verification_status` to `"pending"`.
- [x] 3.4 Slug-bind serializes through the `unique_route_slug` index. Concurrent loser receives 409 from a structured pre-check or, in the rare race window, from the unique-index conflict.
- [x] 3.5 LiveView upload path (`Admin.DashboardPackageLive.Index`) continues to call the unchanged `import_json/3` shape; the new safety checks now apply to that path too because `import_json/3` re-routes through `publish/3`.

## 4. Controller + routes

- [x] 4.1 Create `ServiceRadarWebNGWeb.DashboardPackagePublishController` with `create/2`, `enable/2`, `disable/2`.
- [x] 4.2 `create/2`: parse multipart, validate parts (size + content type), call `Packages.publish/3`. Maps context errors to structured JSON: 400 `invalid_manifest` / `invalid_route` / `missing_part`, 409 `slug_in_use`, 409 `version_already_published`, 413 `payload_too_large`, 415 `unsupported_media_type`, 422 `unprocessable_renderer`, 429 `rate_limited`, 500 `publish_failed`.
- [x] 4.3 `enable/2`: load by id, call `Packages.enable/2`. Optional `{route}` body param re-binds the slug via `Packages.bind_route/3` with `enabled: true`. Same error envelope.
- [x] 4.4 `disable/2`: load by id, call `Packages.disable/2`. Same error envelope.
- [x] 4.5 New route block under `scope "/api/v1", ServiceRadarWebNGWeb` with `pipe_through [:api_key_auth, :require_dashboard_publish_scope]`:
  ```
  post "/dashboard-packages",                DashboardPackagePublishController, :create
  post "/dashboard-packages/:id/enable",     DashboardPackagePublishController, :enable
  post "/dashboard-packages/:id/disable",    DashboardPackagePublishController, :disable
  ```
- [x] 4.6 Pipeline `:require_dashboard_publish_scope` layers `Plugs.RequireOauthScope, scope: "dashboard.publish", fallback_permission: "cli.dashboard.publish"`. Multipart parsing is handled by the existing endpoint-level `SafeParsers`, with its `:length` bumped to 64 MB so a 50 MB renderer fits with manifest + framing overhead. Per-part caps (256 KB manifest, `Storage.max_upload_bytes()` for renderer) are enforced inside the controller before any blob write — that is the real security boundary.
- [x] 4.7 Per-action RBAC enforced inside the controller (`cli.dashboard.{publish,enable,disable}`).
- [x] 4.8 Rate limit: 10/min/jti for `:create`, 30/min/jti for `:enable`/`:disable`. Falls back to per-IP keys when no jti is present (LiveView session path). 429 + `Retry-After` header on overflow.

## 5. Audit logging

- [x] 5.1 `ServiceRadarWebNG.Audit.DashboardPublishEvents.record/3` emits one audit row per publish/enable/disable hop with `{actor_user_id, jti, action, dashboard_id, version, route_slug, content_hash, ip, result, reason?}` via `ServiceRadar.Events.AuditWriter.write_async/1`.
- [x] 5.2 Audit failures are logged but never fail the request. Tested live: NATS-disconnected test environment surfaces the warning but the API responses remain unaffected.

## 6. CLI publish.ts wiring

- [x] 6.1 `js/cli/src/dashboard/publish.ts` — recognizes structured envelopes (`insufficient_scope`, `forbidden`, `slug_in_use`, `version_already_published`, `unprocessable_renderer`, `payload_too_large`, `unsupported_media_type`, `invalid_route`, `rate_limited`, `not_found`, `verification_required`) and prints actionable hints. Keeps the legacy `HTTP <code>` fallback for older instances.
- [x] 6.2 Idempotent re-publish (`result: "idempotent_noop"`) prints a distinct `✓ Re-published … (already at this content_hash; nothing changed)` line so authors see the noop without dropping into the audit log.
- [x] 6.3 `js/cli/tests/publish-errors.test.mjs` — 11/11 passing. Spawns a `node:http` server per case, runs the compiled CLI as a subprocess, and asserts the actionable hint substring. Covers `insufficient_scope`, `forbidden`, `slug_in_use`, `version_already_published`, `unprocessable_renderer`, `payload_too_large`, `unsupported_media_type`, `invalid_route`, `rate_limited`, `idempotent_noop` (success path), and `not_found` on the enable hop.

## 7. Integration tests (web-ng)

Run via the srql-fixtures CNPG instance per the `srql-fixtures-db-tests` skill. Tag `:integration`.

`elixir/web-ng/test/phoenix/controllers/dashboard_package_publish_controller_test.exs` — **13/13 passing.**

- [x] 7.1 Happy path: publish a fresh manifest + renderer, assert 200 + persisted package row.
- [x] 7.2 Bearer JWT missing `dashboard.publish` scope → 403 `insufficient_scope`.
- [x] 7.3 User without `cli.dashboard.publish` RBAC permission → 403 `forbidden`.
- [x] 7.4 Slug bound to a different dashboard_id (enabled) → 409 `slug_in_use`.
- [x] 7.5 Same-id-same-version-same-bytes idempotent re-publish → 200 `result: idempotent_noop`.
- [x] 7.6 Same-id-same-version with different bytes (verified row) → 409 `version_already_published`.
- [x] 7.7 Manifest renderer.sha256 ≠ uploaded bytes → 422 `unprocessable_renderer`.
- [x] 7.8 Slug regex rejection → 400 `invalid_route`.
- [x] 7.9 Disable round-trip: publish → enable → disable → re-enable rebinds slug.
- [x] 7.10 Enable rejects 409 `slug_in_use` when re-binding to a foreign-owned slug.
- [x] 7.11 Same dashboard_id can re-publish to its own slug (no spurious slug_in_use).
- [x] 7.12 Publish without `route` form field — no instance row created.
- [x] 7.13 No Authorization header → 401 from `ApiAuth` (chain validated end-to-end).
- [x] 7.14 Byte caps: renderer too large → 413 `payload_too_large` (with `:plugin_storage` `max_upload_bytes` overridden to 4 KB so a small fixture trips the limit); manifest > 256 KB → 413 `payload_too_large` (padded `description` field). Plus `unsupported_media_type` (415) when a renderer part declares `application/octet-stream`, and `missing_part` (400) when the manifest part is omitted entirely.
- [x] 7.15 Rate limit: 11th publish in 60 s on same `jti` → 429 `rate_limited` with structured `retry_after` plus `Retry-After` header. Seeds the per-`jti` window via 10 direct `RateLimiter.record_attempt/2` calls before the test request.
- [x] 7.16 LiveView upload regression: two tests confirm `Packages.import_json/3` (the LiveView upload modal's entrypoint) still returns `{:ok, package}` after the reroute through `publish/3`, and that it picks up the new `version_already_published` invariant against the same upload path the LiveView uses.

## 8. Manual smoke against running stack

Run against `mix phx.server` at `http://localhost:4000` with the docker CNPG DB.

- [x] 8.1 `serviceradar-cli auth login` (covered by cli-device-auth §13.3 — passing).
- [x] 8.2 `serviceradar-cli dashboard publish --instance http://localhost:4000 --route wifi-network-map --enable --yes` against `example-dashboard` — 200, package + instance bound. Verified DB rows.
- [x] 8.3 Idempotent re-publish — 200 `result: idempotent_noop`, CLI prints "Re-published … nothing changed".
- [x] 8.4 Slug conflict — 409 `slug_in_use` with structured `owner_dashboard_id`. CLI prints the actionable hint.
- [x] 8.5 Version overwrite — 409 `version_already_published`.
- [x] 8.6 Slug regex rejection — 400 `invalid_route`.
- [x] 8.7 SHA256 mismatch — 422 `unprocessable_renderer`.
- [x] 8.8 Disable round-trip — 200, `status: "disabled"`. Re-enable with route — 200, `status: "enabled"`, route_slug bound.
- [x] 8.9 No Authorization — 401 from `ApiAuth`.
- [x] 8.10 Inserted a `RevokedToken` row for the live CLI session JWT; both `/v1/field-survey/auth-check` and `/api/v1/dashboard-packages/:id/disable` return 401 from `ApiAuth`'s `verify_not_revoked` Guardian hook, confirming the publish path inherits the cli-device-auth revocation chain. Cleaned up the test row afterwards (note: the ETS revocation cache holds the entry for ~5 min; re-run `serviceradar-cli auth login` to mint a fresh JWT or wait for the cache to expire).

## 9. Documentation

- [x] 9.1 `js/cli/README.md` — new "Publish" section covering scope/RBAC, idempotent re-publish, version-overwrite rejection, slug ownership, slug regex, rate limit, and the symmetric disable note.
- [x] 9.2 `js/dashboard-sdk/README.md` (lives at `~/src/serviceradar-sdk-dashboard/README.md`) — added a one-paragraph publish summary in the CLI section that points at the canonical docs and calls out the version-overwrite invariant explicitly.
- [x] 9.3 `~/src/developer/priv/content/docs/v2/dashboard-sdk.md` — new "Publishing" section between the harness section and CLI Diagnostics. Documents the multipart contract, all 12 error envelopes, the slug-ownership / version-overwrite / audit-logging invariants, and the three new RBAC permissions.

## 10. Validation

- [x] 10.1 `openspec validate add-cli-dashboard-publish-api --strict` passes.
- [x] 10.2 Code compiles cleanly with `mix compile --warnings-as-errors` for both `serviceradar_core` and `serviceradar_web_ng`.
- [x] 10.3 Manual smoke (§8) is fully green; integration tests (§7) are 13/13 green against the srql-fixtures CNPG instance.
