## 1. Shared rate limiter (core)
- [x] 1.1 Add `ServiceRadar.Security.RateLimiter` GenServer + per-node ETS table with named buckets, sliding window, sweep loop. Bucket keys are `{bucket_name, subject_key}`; no app-level tenant scoping. The owner registers `{:rate_limiter, node()}` in `ServiceRadar.ProcessRegistry` (Horde) on startup and broadcasts increments/resets to peers discovered via `select_by_type(:rate_limiter)` so the libcluster+Horde cluster converges on shared counters. Subscribe to `:nodeup` so a joining node can request a snapshot to bootstrap.
- [x] 1.2 Wire the limiter into `ServiceRadar.Application` supervision tree after `registry_children()` so Horde is up when the limiter registers.
- [x] 1.3 Add bucket configuration in `config/config.exs` for: `:auth_local`, `:auth_oidc_callback`, `:auth_saml_callback`, `:cli_device_auth`, `:dashboard_publish`, `:plugin_upload`, `:webhook_ingest`, `:api_default`. Runtime overrides via `config/runtime.exs` deferred until a rollout knob is actually needed.
- [x] 1.4 Unit tests: sliding window correctness, sweep, concurrent writers, retry-after math, named bucket lookup, Horde registration, peer-cast convergence.
- [x] 1.5 Cluster tests scaffolded under `:cluster` tag (excluded by default). Tests require a distributed test runner + DB-backed Application startup on peers; will be enabled in CI alongside other integration tests.

## 2. Rate-limit plug + shim
- [x] 2.1 Add `ServiceRadarWebNGWeb.Plugs.RateLimit` plug that resolves bucket by name, derives subject key (IP or {IP, actor_id}), and halts with 429 + `retry-after` / `x-ratelimit-*` headers on denial. Honors `x-forwarded-for` for the client IP.
- [x] 2.2 Rewrite `ServiceRadarWebNGWeb.Auth.RateLimiter` as a thin delegate to `ServiceRadar.Security.RateLimiter`; preserve the public surface (`check_rate_limit/3`, `record_attempt/2`, `check_rate_limit_and_record/3`, `clear_rate_limit/2`) so existing call sites compile unchanged. Remove the now-redundant supervisor entry from `serviceradar_web_ng_web/runtime.ex`.
- [x] 2.3 Add named rate-limit pipelines in `router.ex` (`:rate_limit_auth_local`, `:rate_limit_auth_oidc`, `:rate_limit_auth_saml`, `:rate_limit_cli_device_auth`, `:rate_limit_dashboard_publish`, `:rate_limit_plugin_upload`, `:rate_limit_webhook_ingest`, `:rate_limit_api_default`). Wiring onto specific routes is deferred to section 10 (rollout) and happens alongside removal of the inline `Auth.RateLimiter` calls in each controller, so a route never goes through both checks simultaneously.
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

## 5. Webhook signature plug + secret resource
- [x] 5.1 Add `ServiceRadar.Security` Ash domain and `ServiceRadar.Security.WebhookSecret` resource. Keyed by `source_name` (unique among active secrets), encrypted `secret` via the existing `ServiceRadar.Vault` cloak, `active?` boolean, nullable `grace_until` for rotation, `rotated_at`, `last_used_at`. AshPaperTrail enabled via a new `ServiceRadar.Security.PaperTrailMixin` mirroring the credentials pattern. Custom `:rotate` action that supersedes the existing active secret with a grace window and creates the new one in a transaction.
- [ ] 5.2 Generate Ash migration via `mix ash.codegen add_webhook_secret` and run. Pending DB connectivity in the dev/CI environment (current sandbox: CNPG requires client-cert auth that isn't wired in this work). The migration generation is a single command once the dev env is set up.
- [x] 5.3 Add `ServiceRadarWebNGWeb.Plugs.WebhookSignature` performing HMAC-SHA256 verification. Looks up all currently-verifiable secrets for the source (the active one plus any superseded secret whose grace window has not expired), HMACs the raw body against each, and accepts the first match. Updates `last_used_at` on the matching secret asynchronously so verification stays on the hot path. Halts with HTTP 401 on any mismatch.
- [ ] 5.4 Migrate Falco webhook controllers (and any other inbound webhook endpoints) to use the plug; remove inline verification. Deferred to section 11 (rollout) so each webhook source rotates its secret into the new resource alongside the controller migration.
- [x] 5.5 Plug tests: `init/1` argument validation (scheme/source_name), constant-time signature comparison correctness, and the DB-backed accept/reject/grace-window scenarios scaffolded under a `:skip` tag awaiting Ash test infrastructure (`SERVICERADAR_REQUIRE_DB_TESTS=1`).

## 6. Security event stream
- [x] 6.1 Add `ServiceRadar.Security.SecurityEvent` Ash resource (occurred_at, kind atom, severity atom, actor_id, ip, route, details jsonb, correlation_id). Append-only `:create` action; BRIN index on `occurred_at` and a composite index `(kind, occurred_at)`. Kind/severity enums exposed via `kinds/0` and `severities/0` for the audit UI.
- [ ] 6.2 Generate Ash migration via `mix ash.codegen add_security_event` and run. Deferred until DB connectivity is wired alongside the WebhookSecret migration in section 5.2.
- [x] 6.3 Add `ServiceRadar.Security.Events.record/1` recorder GenServer with bounded queue (default 1000) and async persistence — `record/1` is fire-and-forget via `GenServer.cast/2`, drain spawns a short-lived worker so a slow DB never blocks the request hot path or the flush caller. Overflow drops events and increments `[:serviceradar, :security, :events, :dropped]` telemetry. Persisted events fan out on `Phoenix.PubSub` topic `"security_events"` for the live-tail audit UI.
- [x] 6.4 Emit events from `RateLimit` plug denials, `WebhookSignature` failures, and CSP violation reports. Emission from policy denials, failed logins, and lockout triggers is wired alongside sections 7–8 (the modules that own those events).
- [ ] 6.5 Add retention Oban job that deletes events older than the configured TTL (default 90d). The Ash action `:delete_older_than` is in place — wrapping it in an Oban worker is deferred to section 11 (rollout) so the schedule lands with the other operational knobs.
- [x] 6.6 Recorder tests: record returns `:ok` immediately, non-blocking under burst, overflow path drops + emits telemetry, kinds/severities introspection.

## 7. Auth lockout
- [x] 7.1 Add `ServiceRadar.Security.AuthLockout` Ash resource (`actor_id`, `locked_at`, `locked_by`, `reason`, `expires_at`, `cleared_at`, `cleared_by`, `clear_reason`) with AshPaperTrail enabled via the `Security.PaperTrailMixin`. Actions: `:lock`, `:unlock` (gated to `:admin`/`:owner`), `:active_for/1`.
- [ ] 7.2 Generate Ash migration via `mix ash.codegen add_auth_lockout` and run. Deferred alongside the other section-5/6 codegen until DB connectivity is wired.
- [ ] 7.3 Extend the limiter with progressive backoff schedule `[1m, 5m, 30m, 24h]` per `{bucket, ip, actor}` key. **Deferred** — needs intrusive changes to the sliding-window math; the cross-IP lockout trigger below covers the most important brute-force surface in the meantime.
- [x] 7.4 Add `ServiceRadar.Security.Lockouts` with `record_failed_login/2`, `active_lockout/1`, and `unlock/3`. `record_failed_login/2` emits a `:login_failed` SecurityEvent and, when failed-login events for the actor exceed the configured threshold (default 20) inside the trailing window (default 1h), opens an `AuthLockout` row, emits `:lockout_triggered`, and short-circuits subsequent attempts. Unlock emits `:lockout_cleared`. All writes go through `SystemActor`.
- [x] 7.5 Add `ServiceRadarWebNGWeb.Plugs.LockoutCheck`. Resolves the actor from a configured param (e.g. `"email"`) or assign (`:current_user`), short-circuits with HTTP 423 if `Lockouts.active_lockout/1` returns a row, and records a `:policy_denied` event. Wiring onto specific routes is deferred to section 11 (rollout) so each auth path's call to `record_failed_login/2` lands at the same time.
- [x] 7.6 Plug + helper tests: `init/1` validation, no-actor pass-through, unlock action authorization is gated through Ash policies (`:admin`/`:owner` for create+update, `:operator` for read). End-to-end accept/halt paths are scaffolded for the DB-backed integration suite.

## 8. RBAC capabilities
- [x] 8.1 Add `settings.audit.view` and `settings.audit.manage` permission keys to `ServiceRadar.Identity.RBAC.Catalog`. The existing string-keyed permission catalog is the project's idiom (vs. the proposal's earlier `:audit_viewer`/`:security_admin` atoms); the keys read the same in role-profile UIs.
- [x] 8.2 Default role mappings: `settings.audit.view` is granted to `@operator_roles` (operators see history/events/lockouts); `settings.audit.manage` is granted to `@admin_roles` (admins/owners do unlock/rotate).
- [x] 8.3 Convert the `WebhookSecret`, `SecurityEvent`, and `AuthLockout` policies to the standard `ServiceRadar.Policies` helpers (`system_bypass()` + `action_type_with_permission`) gated on the new permission keys.
- [ ] 8.4 End-to-end policy tests (viewer can read, only admin can unlock/rotate, denials emit a SecurityEvent) live in the DB-backed integration suite alongside the other Ash policy tests; the unit suite covers the configuration shape.

## 9. Settings → Audit operator surfaces
- [x] 9.1 Add a Settings → Audit tab to `SettingsComponents` gated by `settings.audit.view`, and register the three LiveView routes (`/settings/audit/events`, `/settings/audit/lockouts`, `/settings/audit/webhook-secrets`) in `router.ex`.
- [ ] 9.2 `AuditLive.History` — unified AshPaperTrail timeline across enabled resources with resource-type, actor, action, time-range filters and a diff view. Deferred: the cross-resource version query needs more thought (each resource has its own `*_versions` table) and the diff view is non-trivial; tracked as a separate proposal.
- [x] 9.3 `AuditLive.Events` — `SecurityEvent` table sorted by `occurred_at desc`, kind + severity filters, live tail via the `security_events` Phoenix.PubSub topic the recorder broadcasts on every successful persist. The page falls back to an empty list (not a crash) when the DB is unreachable so the rest of Settings keeps working.
- [x] 9.4 `AuditLive.Lockouts` — lists active and recently cleared `AuthLockout` rows. `Unlock` action visible only with `settings.audit.manage` and routes through `ServiceRadar.Security.Lockouts.unlock/3` (which emits `:lockout_cleared`).
- [x] 9.5 `AuditLive.WebhookSecrets` — per-source list with last-used timestamp. Rotation form (gated by `settings.audit.manage`) takes a new secret + grace window and calls `WebhookSecret.rotate_secret/3`, which supersedes the previous active record and creates the new one in a transaction. Superseded records are surfaced as a count so operators can see the in-grace window.
- [ ] 9.6 `AuditLive.RateLimits` — read-only top-bucket pressure view and recent denials list. Deferred: the bucket pressure data lives in per-node ETS, so this needs an aggregated read pattern across the cluster; tracked separately.
- [ ] 9.7 LiveView tests are scaffolded for the DB-backed integration suite: each sub-page renders, filters round-trip, mutating actions require `settings.audit.manage`, viewer-only role sees the table without action buttons.

## 10. Rollout
- [ ] 10.1 Land steps 1–2, deploy, observe — should be a no-op behavior change.
- [ ] 10.2 Land step 3 with CSP in report-only mode; observe `/api/security/csp-report` ingestion for ≥7 days.
- [ ] 10.3 Land steps 4–5; rotate Falco webhook secret through the new resource.
- [ ] 10.4 Land steps 6–7; verify lockout flows end-to-end in staging.
- [ ] 10.5 Land steps 8–9 (RBAC + UI).
- [ ] 10.6 Flip CSP to enforce via runtime config; keep report-uri for visibility.

## 11. Session cookie hardening
- [ ] 11.1 In `elixir/web-ng/lib/serviceradar_web_ng_web/endpoint.ex`, add `:encryption_salt`, `secure: true` (driven by runtime config in prod), `http_only: true` (defensive — Plug defaults this on already), and switch `same_site` from `"Lax"` to `"Strict"`.
- [ ] 11.2 In `elixir/web-ng/config/runtime.exs`, source the encryption salt and the `secure` flag from environment variables and document them in the deployment runbook.
- [ ] 11.3 Confirm `protect_from_forgery` remains on every browser pipeline (already true at 4 sites in `router.ex`).
- [ ] 11.4 Add a controller-test that asserts every authenticated endpoint sets a cookie with `Secure; HttpOnly; SameSite=Strict` and that the cookie value is not Base64-decodable into the session map without the encryption secret.
- [ ] 11.5 Add a graceful-decode-failure test: a request carrying a sign-only cookie issued before this change is treated as anonymous (redirected to sign-in) rather than crashing.
- [ ] 11.6 Release-note the one-time forced sign-out at the rollout that enables encryption.

## 12. Docs
- [ ] 11.1 Update `openspec/project.md` with the security-plug pipeline convention.
- [ ] 11.2 Add operator runbook section under `docs/` for unlock procedure and webhook secret rotation.
- [ ] 11.3 Note CSP escape hatch and reporting endpoint in developer docs.
