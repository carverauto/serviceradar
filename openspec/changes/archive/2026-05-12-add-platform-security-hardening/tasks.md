## 1. Shared rate limiter (core)
- [x] 1.1 Add `ServiceRadar.Security.RateLimiter` GenServer + per-node ETS table with named buckets, sliding window, sweep loop. Bucket keys are `{bucket_name, subject_key}`; no app-level tenant scoping. The owner registers `{:rate_limiter, node()}` in `ServiceRadar.ProcessRegistry` (Horde) on startup and broadcasts increments/resets to peers discovered via `select_by_type(:rate_limiter)` so the libcluster+Horde cluster converges on shared counters. Subscribe to `:nodeup` so a joining node can request a snapshot to bootstrap.
- [x] 1.2 Wire the limiter into `ServiceRadar.Application` supervision tree after `registry_children()` so Horde is up when the limiter registers.
- [x] 1.3 Add bucket configuration in `config/config.exs` for: `:auth_local`, `:auth_oidc_callback`, `:auth_saml_callback`, `:cli_device_auth`, `:dashboard_publish`, `:plugin_upload`, `:api_default`. Runtime overrides via `config/runtime.exs` deferred until a rollout knob is actually needed.
- [x] 1.4 Unit tests: sliding window correctness, sweep, concurrent writers, retry-after math, named bucket lookup, Horde registration, peer-cast convergence.
- [x] 1.5 Cluster tests scaffolded under `:cluster` tag (excluded by default). Tests require a distributed test runner + DB-backed Application startup on peers; will be enabled in CI alongside other integration tests.

## 2. Rate-limit plug + shim
- [x] 2.1 Add `ServiceRadarWebNGWeb.Plugs.RateLimit` plug that resolves bucket by name, derives subject key (IP or {IP, actor_id}), and halts with 429 + `retry-after` / `x-ratelimit-*` headers on denial. Honors `x-forwarded-for` for the client IP.
- [x] 2.2 Rewrite `ServiceRadarWebNGWeb.Auth.RateLimiter` as a thin delegate to `ServiceRadar.Security.RateLimiter`; preserve the public surface (`check_rate_limit/3`, `record_attempt/2`, `check_rate_limit_and_record/3`, `clear_rate_limit/2`) so existing call sites compile unchanged. Remove the now-redundant supervisor entry from `serviceradar_web_ng_web/runtime.ex`.
- [x] 2.3 Add named rate-limit pipelines in `router.ex` (`:rate_limit_auth_local`, `:rate_limit_auth_oidc`, `:rate_limit_auth_saml`, `:rate_limit_cli_device_auth`, `:rate_limit_dashboard_publish`, `:rate_limit_plugin_upload`, `:rate_limit_api_default`). Wiring onto specific routes is deferred to section 10 (rollout) and happens alongside removal of the inline `Auth.RateLimiter` calls in each controller, so a route never goes through both checks simultaneously.
- [x] 2.4 Plug tests: happy path with informational headers, denial halt with 429 + `retry-after`, per-IP isolation, `x-forwarded-for` honoring, `:ip_and_actor` keying for password-spray defense, config-driven bucket lookup. (The web-ng test suite gates on DB reachability via `Mix.Tasks.Serviceradar.MaybeTest`; the new plug tests run automatically alongside the rest of the web-ng suite when CI brings the DB up.)

## 3. Security headers plug
- [x] 3.1 Add `ServiceRadarWebNGWeb.Plugs.SecurityHeaders` adding HSTS (HTTPS only) and Permissions-Policy on top of Phoenix's defaults, plus a CSP `:enforce`/`:report_only` toggle that rewrites the response header without touching the CSP body. Referrer-Policy and X-Permitted-Cross-Domain-Policies are already set by Phoenix's `put_secure_browser_headers/2` so we don't duplicate them.
- [x] 3.2 Wire the plug into every web-ng pipeline that produces user-facing responses: `:browser`, `:browser_raw_auth`, `:api`, `:api_docs_ui`, `:api_auth`, `:api_key_auth`, `:api_token_auth`, `:ash_json_api`. The plug runs *after* `put_secure_browser_headers` so it can rewrite the CSP that pipeline already set.
- [x] 3.3 Add `ServiceRadarWebNGWeb.CspReportController` and route `POST /api/security/csp-report` on its own minimal pipeline (`:csp_report`) that accepts `application/json`, `application/csp-report`, and `application/reports+json`. Until SecurityEvent lands (section 6) the controller logs reports at `info` with a `csp_violation` tag; section 6 swaps to `ServiceRadar.Security.Events.record/1`.
- [x] 3.4 Runtime config in `config/config.exs`: `csp_mode: :report_only` and `csp_report_uri: "/api/security/csp-report"` by default. Operators flip to `:enforce` after the bake-in week. Runtime config takes precedence over plug opts.
- [x] 3.5 Plug tests cover HSTS gating on scheme, default and overridden Permissions-Policy, CSP enforce vs report-only header rewrite, report-uri appending, and runtime-config-wins-over-plug-opts. (Web-ng test suite gates on DB reachability via `Mix.Tasks.Serviceradar.MaybeTest`; the new tests run in CI alongside the rest.)

## 4. Upload guard plug
- [x] 4.1 Add `ServiceRadarWebNGWeb.Plugs.UploadGuard` with magic-number detection (PNG/JPEG/GIF/ZIP/WASM/PDF), size cap, filename sanitization (strips control chars and path separators, truncates to 120 bytes preserving extension), and randomized storage-name generation (`<millis>-<base64url(12 bytes)><ext>`). Metadata attached to `conn.assigns.upload_guard` per param.
- [ ] 4.2 Apply guard to plugin upload (`/api/plugins/upload`) and dashboard package publish (`/api/v1/dashboard-packages`); remove the inline checks from those controllers. Deferred to section 11 (rollout) so each controller is migrated alongside its existing checks, not in parallel.
- [x] 4.3 Plug tests: happy path PNG accept, multi-param accept, missing-param no-op, magic mismatch 415, oversized 413, non-upload param 400, `sanitize_filename/1` control-char + path-separator + truncation + empty fallback, `init/1` validation of allowed kinds.

## 5. Webhook signature plug + secret resource — DROPPED
Removed from scope: serviceradar has no inbound HTTP webhook surface today (Falco alerts and datasource pushes flow over NATS, not HTTP). The plug, the `WebhookSecret` resource, and the Settings → Audit → Webhook Secrets sub-page solved a problem the codebase doesn't have. If an inbound HTTP webhook surface appears later, the code from earlier on this branch (commit `14047f0f4`) is a reasonable starting point.

## 6. Security event stream
- [x] 6.1 Add `ServiceRadar.Security.SecurityEvent` Ash resource (occurred_at, kind atom, severity atom, actor_id, ip, route, details jsonb, correlation_id). Append-only `:create` action; BRIN index on `occurred_at` and a composite index `(kind, occurred_at)`. Kind/severity enums exposed via `kinds/0` and `severities/0` for the audit UI.
- [x] 6.2 Migration: hand-written `priv/repo/migrations/20260512040000_add_security_resources.exs` matching the project's existing pattern (every migration in this directory uses `use Ecto.Migration` directly; `mix ash.codegen` is currently blocked on gitignored snapshots — see Forgejo issue #3269). Idempotent (`CREATE TABLE IF NOT EXISTS` / `CREATE INDEX IF NOT EXISTS` / `drop_if_exists` on down), verified against local CNPG plus end-to-end CRUD smoke tests for `SecurityEvent` and `AuthLockout`.
- [x] 6.3 Add `ServiceRadar.Security.Events.record/1` recorder GenServer with bounded queue (default 1000) and async persistence — `record/1` is fire-and-forget via `GenServer.cast/2`, drain spawns a short-lived worker so a slow DB never blocks the request hot path or the flush caller. Overflow drops events and increments `[:serviceradar, :security, :events, :dropped]` telemetry. Persisted events fan out on `Phoenix.PubSub` topic `"security_events"` for the live-tail audit UI.
- [x] 6.4 Emit events from `RateLimit` plug denials and CSP violation reports. Emission from failed logins and lockout triggers is wired alongside section 7 (`ServiceRadar.Security.Lockouts`).
- [x] 6.5 `ServiceRadar.Jobs.SecurityEventsRetentionWorker` Oban worker wraps `SecurityEvent.delete_older_than/1` with a 90-day default (overridable via `config :serviceradar_core, ServiceRadar.Jobs.SecurityEventsRetentionWorker, retention_days: N`). Scheduled daily at 03:23 UTC in the platform cron. Smoke-tested locally against CNPG: a 200-day-old row is pruned while a fresh row survives.
- [x] 6.6 Recorder tests: record returns `:ok` immediately, non-blocking under burst, overflow path drops + emits telemetry, kinds/severities introspection.

## 7. Auth lockout
- [x] 7.1 Add `ServiceRadar.Security.AuthLockout` Ash resource (`actor_id`, `locked_at`, `locked_by`, `reason`, `expires_at`, `cleared_at`, `cleared_by`, `clear_reason`) with AshPaperTrail enabled via the `Security.PaperTrailMixin`. Actions: `:lock`, `:unlock` (gated to `:admin`/`:owner`), `:active_for/1`.
- [x] 7.2 Migration: included in `priv/repo/migrations/20260512040000_add_security_resources.exs` (see 5.2).
- [ ] 7.3 Extend the limiter with progressive backoff schedule `[1m, 5m, 30m, 24h]` per `{bucket, ip, actor}` key. **Deferred** — needs intrusive changes to the sliding-window math; the cross-IP lockout trigger below covers the most important brute-force surface in the meantime.
- [x] 7.4 Add `ServiceRadar.Security.Lockouts` with `record_failed_login/2`, `active_lockout/1`, and `unlock/3`. `record_failed_login/2` emits a `:login_failed` SecurityEvent and, when failed-login events for the actor exceed the configured threshold (default 20) inside the trailing window (default 1h), opens an `AuthLockout` row, emits `:lockout_triggered`, and short-circuits subsequent attempts. Unlock emits `:lockout_cleared`. All writes go through `SystemActor`.
- [x] 7.5 Add `ServiceRadarWebNGWeb.Plugs.LockoutCheck`. Resolves the actor from a configured param (e.g. `"email"`) or assign (`:current_user`), short-circuits with HTTP 423 if `Lockouts.active_lockout/1` returns a row, and records a `:policy_denied` event. Wiring onto specific routes is deferred to section 11 (rollout) so each auth path's call to `record_failed_login/2` lands at the same time.
- [x] 7.6 Plug + helper tests: `init/1` validation, no-actor pass-through, unlock action authorization is gated through Ash policies (`:admin`/`:owner` for create+update, `:operator` for read). End-to-end accept/halt paths are scaffolded for the DB-backed integration suite.

## 8. RBAC capabilities
- [x] 8.1 Add `settings.audit.view` and `settings.audit.manage` permission keys to `ServiceRadar.Identity.RBAC.Catalog`. The existing string-keyed permission catalog is the project's idiom (vs. the proposal's earlier `:audit_viewer`/`:security_admin` atoms); the keys read the same in role-profile UIs.
- [x] 8.2 Default role mappings: `settings.audit.view` is granted to `@operator_roles` (operators see history/events/lockouts); `settings.audit.manage` is granted to `@admin_roles` (admins/owners do unlock/rotate).
- [x] 8.3 Convert the `SecurityEvent` and `AuthLockout` policies to the standard `ServiceRadar.Policies` helpers (`system_bypass()` + `action_type_with_permission`) gated on the new permission keys.
- [ ] 8.4 End-to-end policy tests (viewer can read, only admin can unlock/rotate, denials emit a SecurityEvent) live in the DB-backed integration suite alongside the other Ash policy tests; the unit suite covers the configuration shape.

## 9. Settings → Audit operator surfaces
- [x] 9.1 Add a Settings → Audit tab to `SettingsComponents` gated by `settings.audit.view`, and register the two LiveView routes (`/settings/audit/events`, `/settings/audit/lockouts`) in `router.ex`.
- [ ] 9.2 `AuditLive.History` — unified AshPaperTrail timeline across enabled resources with resource-type, actor, action, time-range filters and a diff view. Deferred: the cross-resource version query needs more thought (each resource has its own `*_versions` table) and the diff view is non-trivial; tracked as a separate proposal.
- [x] 9.3 `AuditLive.Events` — `SecurityEvent` table sorted by `occurred_at desc`, kind + severity filters, live tail via the `security_events` Phoenix.PubSub topic the recorder broadcasts on every successful persist. The page falls back to an empty list (not a crash) when the DB is unreachable so the rest of Settings keeps working.
- [x] 9.4 `AuditLive.Lockouts` — lists active and recently cleared `AuthLockout` rows. `Unlock` action visible only with `settings.audit.manage` and routes through `ServiceRadar.Security.Lockouts.unlock/3` (which emits `:lockout_cleared`).
- [ ] 9.6 `AuditLive.RateLimits` — read-only top-bucket pressure view and recent denials list. Deferred: the bucket pressure data lives in per-node ETS, so this needs an aggregated read pattern across the cluster; tracked separately.
- [ ] 9.7 LiveView tests are scaffolded for the DB-backed integration suite: each sub-page renders, filters round-trip, mutating actions require `settings.audit.manage`, viewer-only role sees the table without action buttons.

## 10. Rollout
- [ ] 10.1 Land steps 1–2, deploy, observe — should be a no-op behavior change.
- [ ] 10.2 Land step 3 with CSP in report-only mode; observe `/api/security/csp-report` ingestion for ≥7 days.
- [ ] 10.3 Land step 4 (UploadGuard); section 5 was dropped from scope (no webhooks).
- [ ] 10.4 Land steps 6–7; verify lockout flows end-to-end in staging.
- [ ] 10.5 Land steps 8–9 (RBAC + UI).
- [ ] 10.6 Flip CSP to enforce via runtime config; keep report-uri for visibility.

## 11. Session cookie hardening
- [x] 11.1 In `elixir/web-ng/lib/serviceradar_web_ng_web/endpoint.ex`, add `:encryption_salt`, `secure: Mix.env() == :prod`, `http_only: true` (defensive — `Plug.Session` defaults this on already), and switch `same_site` from `"Lax"` to `"Strict"`. The encryption key is derived from `SECRET_KEY_BASE`, so the cookie value is opaque to anyone without that secret.
- [ ] 11.2 Source the encryption salt and `secure` flag from runtime env vars. Deferred: the static salt + compile-time `Mix.env()` switch covers the production case (where `SECRET_KEY_BASE` is the actual secret), and pulling the salt into runtime config would force a session invalidation at every deploy.
- [x] 11.3 Confirmed `protect_from_forgery` is on every browser pipeline (`:browser`, `:browser_raw_auth`, `:api_auth`, `:ash_json_api` — 4 sites in `router.ex`).
- [ ] 11.4 Controller test asserting `Secure; HttpOnly; SameSite=Strict` on every authenticated response and that the cookie value is opaque without the encryption secret. Lives in the DB-backed integration suite (Phoenix.ConnTest needs the full endpoint to drive sessions end-to-end).
- [ ] 11.5 Graceful-decode test for sign-only cookies issued before this change — `Plug.Session.COOKIE`'s default behavior already treats a undecryptable cookie as no session, but pinning it down with a regression test is worth doing in the integration suite.
- [ ] 11.6 Release-note the one-time forced sign-out — captured as a follow-up alongside the rollout-step CHANGELOG entry.

## 12. Docs
- [x] 12.1 Add an operator runbook for the rollout order, env-var requirements, bucket tuning, lockout clearing, CSP escape hatch, and known follow-ups: `docs/PLATFORM_SECURITY_HARDENING.md`.
- [ ] 12.2 Cross-link from `openspec/project.md` once the rollout completes. Deferred — `project.md` is rewritten when `archive`-ing the change, so the link lands then.
