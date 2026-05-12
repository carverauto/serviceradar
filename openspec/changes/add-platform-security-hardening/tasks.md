## 1. Shared rate limiter (core)
- [x] 1.1 Add `ServiceRadar.Security.RateLimiter` GenServer + per-node ETS table with named buckets, sliding window, sweep loop. Bucket keys are `{bucket_name, subject_key}`; no app-level tenant scoping. The owner joins a `:pg` group on startup and broadcasts increments/resets to peers so the libcluster+Horde cluster converges on shared counters. Subscribe to `:nodeup` so a joining node can request a snapshot to bootstrap.
- [x] 1.2 Wire the limiter into `ServiceRadar.Application` supervision tree before any web app (also supervise the `:pg` default scope since OTP 25+ does not auto-start it).
- [x] 1.3 Add bucket configuration in `config/config.exs` for: `:auth_local`, `:auth_oidc_callback`, `:auth_saml_callback`, `:cli_device_auth`, `:dashboard_publish`, `:plugin_upload`, `:webhook_ingest`, `:api_default`. Runtime overrides via `config/runtime.exs` deferred until a rollout knob is actually needed.
- [x] 1.4 Unit tests: sliding window correctness, sweep, concurrent writers, retry-after math, named bucket lookup, `:pg` group membership, peer-cast convergence.
- [x] 1.5 Cluster tests scaffolded under `:cluster` tag (excluded by default). Tests require a distributed test runner + DB-backed Application startup on peers; will be enabled in CI alongside other integration tests.

## 2. Rate-limit plug + shim
- [ ] 2.1 Add `ServiceRadarWebNGWeb.Plugs.RateLimit` plug that resolves bucket by name, derives subject key (IP or {IP, actor_id}), and halts with 429 + `retry-after` / `x-ratelimit-*` headers on denial.
- [ ] 2.2 Rewrite `ServiceRadarWebNGWeb.Auth.RateLimiter` to delegate `check_rate_limit/2` and `record_attempt/2` to the shared limiter; preserve public signature so existing call sites compile unchanged.
- [ ] 2.3 Add named rate-limit pipelines in `router.ex` and wire them onto: `/api/cli-auth/*`, `/auth/oidc/callback`, `/auth/saml/callback`, `/auth/local`, `/api/dashboards/publish`, `/api/plugins/upload`, `/api/webhooks/*`.
- [ ] 2.4 Plug tests: happy path, denial, retry-after header presence, header values, halts before controller.

## 3. Security headers plug
- [ ] 3.1 Add `ServiceRadarWebNGWeb.Plugs.SecurityHeaders`: CSP (initially report-only), HSTS (when scheme is https), Referrer-Policy, Permissions-Policy, X-Permitted-Cross-Domain-Policies.
- [ ] 3.2 Wire into `:browser` and `:api` pipelines in `router.ex` (or `endpoint.ex` for blanket coverage) ahead of route-specific plugs.
- [ ] 3.3 Add `/api/security/csp-report` endpoint that ingests CSP violation reports into the `SecurityEvent` stream.
- [ ] 3.4 Add `:csp_enforce` runtime config toggle and a per-route `disable_csp` opt for escape hatches.
- [ ] 3.5 Plug tests verifying header presence, report-only vs enforce mode, and disable-csp opt-out.

## 4. Upload guard plug
- [ ] 4.1 Add `ServiceRadarWebNGWeb.Plugs.UploadGuard` with magic-number detection (PNG/JPEG/ZIP/WASM), size caps, filename sanitization, and randomized storage name generation.
- [ ] 4.2 Apply guard to plugin upload (`/api/plugins/upload`) and dashboard package publish (`/api/dashboards/publish`); remove the inline checks from those controllers.
- [ ] 4.3 Plug tests: accept on magic-match, reject on mismatched extension vs magic, reject over-size, sanitize control chars in filenames, randomized storage name format.

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
