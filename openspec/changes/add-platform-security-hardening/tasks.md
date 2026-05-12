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
- [ ] 5.1 Add `ServiceRadar.Security.WebhookSecret` Ash resource (`source_name` primary key, `encrypted_value` via Vault cloak, `superseded_by_id`, `last_used_at`) with AshPaperTrail enabled via `PaperTrailMixin`.
- [ ] 5.2 Generate Ash migration via `mix ash.codegen add_webhook_secret` and run.
- [ ] 5.3 Add `ServiceRadarWebNGWeb.Plugs.WebhookSignature` performing HMAC-SHA256 verification with two-secret grace window.
- [ ] 5.4 Migrate Falco webhook controllers (and any other inbound webhook endpoints) to use the plug; remove inline verification.
- [ ] 5.5 Tests: valid sig, invalid sig, expired secret, grace-window acceptance of superseded secret, missing secret yields 401.

## 6. Security event stream
- [ ] 6.1 Add `ServiceRadar.Security.SecurityEvent` Ash resource (occurred_at, kind, severity, actor_id, ip, route, details jsonb, correlation_id). Append-only `:create` action; index `(occurred_at desc)` and `(kind, occurred_at desc)`.
- [ ] 6.2 Generate Ash migration via `mix ash.codegen add_security_event` and run.
- [ ] 6.3 Add `ServiceRadar.Security.Events.record/1` recorder with bounded queue + writer process; drop-on-overflow with telemetry counter.
- [ ] 6.4 Emit events from: `RateLimit` plug denials, `WebhookSignature` failures, Ash policy denials (via global policy bypass logger), failed login attempts in `auth_controller` and OIDC/SAML controllers, lockout triggers/clears, CSP violation reports.
- [ ] 6.5 Add retention Oban job that deletes events older than the configured TTL (default 90d).
- [ ] 6.6 Tests: record path, overflow drop, retention deletes only expired rows.

## 7. Auth lockout
- [ ] 7.1 Add `ServiceRadar.Security.AuthLockout` Ash resource (actor_id, locked_at, locked_by, expires_at, reason) with AshPaperTrail. Actions: `:lock`, `:unlock` (requires `:security_admin`).
- [ ] 7.2 Generate Ash migration via `mix ash.codegen add_auth_lockout` and run.
- [ ] 7.3 Extend the limiter with progressive backoff schedule `[1m, 5m, 30m, 24h]` per `{bucket, ip, actor}` key.
- [ ] 7.4 Add cross-IP lockout trigger: when `failed_login` events for an actor exceed N (default 20) within 1h, create an `AuthLockout` row.
- [ ] 7.5 Plug `LockoutCheck` placed before auth controllers/LiveViews that short-circuits locked actors with a generic message.
- [ ] 7.6 Tests: backoff progression, lockout trigger threshold, unlock requires admin capability, locked attempts emit SecurityEvent.

## 8. RBAC capabilities
- [ ] 8.1 Add `:audit_viewer` and `:security_admin` capabilities to the RBAC catalog.
- [ ] 8.2 Default role mappings: `:owner` and `:admin` get `:security_admin`; `:operator` gets `:audit_viewer`.
- [ ] 8.3 Ash policies on `SecurityEvent`, `AuthLockout`, `WebhookSecret` require the appropriate capability for read/write.
- [ ] 8.4 Tests: viewer can read events, only admin can unlock/rotate, denials emit a SecurityEvent.

## 9. Settings → Audit operator surfaces
- [ ] 9.1 Add Settings → Audit top-level nav entry (gated by `:audit_viewer`) and route group in `router.ex`.
- [ ] 9.2 `AuditLive.History` — unified AshPaperTrail timeline across enabled resources with resource-type, actor, action, time-range filters; diff view for selected version.
- [ ] 9.3 `AuditLive.Events` — `SecurityEvent` table with filters (kind, severity, actor, ip, route, time range), CSV export, live tail via Phoenix.PubSub.
- [ ] 9.4 `AuditLive.Lockouts` — list locked accounts; unlock action gated by `:security_admin`.
- [ ] 9.5 `AuditLive.WebhookSecrets` — per-source secret list with rotate action and last-used timestamp.
- [ ] 9.6 `AuditLive.RateLimits` — read-only top-bucket pressure view and recent denials list.
- [ ] 9.7 LiveView tests: each sub-page renders, filters round-trip, mutating actions require `:security_admin`, viewer-only role sees redacted/disabled controls.

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
