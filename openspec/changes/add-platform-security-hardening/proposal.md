# Change: Platform security hardening (rate limiting, headers, input hardening, audit)

## Why

ServiceRadar's web-facing Phoenix surface (`elixir/web-ng`) currently relies on Phoenix defaults plus a narrow ETS-backed auth rate limiter (`ServiceRadarWebNGWeb.Auth.RateLimiter`). Several gaps surfaced while bringing the AWX/Ansible, Proxmox console, and dashboard publish flows online:

- Non-auth endpoints (CLI device-auth, OAuth/OIDC callbacks, SAML callbacks, dashboard package publish, plugin upload) have no per-IP throttling — they're trivially brute-forceable or fillable.
- Response headers are Phoenix defaults only. No CSP, HSTS, Referrer-Policy, or Permissions-Policy, which leaves XSS / clickjacking / referrer-leak defenses partial.
- Inbound binary uploads (plugin packages, dashboard assets) lack magic-number content-type detection, size caps, and filename sanitization beyond what individual controllers re-implement.
- Failed-auth and policy-denial events are not captured in a queryable audit stream. AshPaperTrail covers resource versioning on a growing set of resources, but stateless security events (failed logins, rate-limit hits, policy denials, signature failures) have no persistent home.
- Sustained brute-force against the auth rate limiter results in a 429 storm with no escalation (no progressive backoff, no account-level lockout, no operator alert).
- **Session cookie is signed but not encrypted, not pinned to HTTPS, and SameSite=Lax.** The comment in `elixir/web-ng/lib/serviceradar_web_ng_web/endpoint.ex:6` flags this directly: "Set `:encryption_salt` if you would also like to encrypt it." Anyone who reads the cookie value can read the entire session payload (`:user_token_key`, OIDC/SAML state, sudo timestamps, return paths). The cookie is not marked `Secure`, so it can leak over plain HTTP if a deployment misconfigures TLS. `SameSite=Lax` is fine for general apps but weaker than needed for an ops console.

A sibling project (`inkit`) recently shipped a coherent set of plugs for the same gaps; we want to port the patterns, adapt them to ServiceRadar's Ash conventions, and consolidate the existing ad-hoc auth limiter into the new shared surface. Note that ServiceRadar's tenancy model is infrastructure-level (per-tenant k8s namespace + CNPG schema + NATS account), so the new surfaces here are deployment-wide rather than per-tenant-scoped.

## What Changes

- **ADD** a generic `ServiceRadarWebNGWeb.Plugs.RateLimit` plug backed by a **cluster-aware ETS limiter** (`ServiceRadar.Security.RateLimiter`): each web-ng node keeps its own local ETS table for low-latency reads, registers itself in `ServiceRadar.ProcessRegistry` (the existing Horde-backed registry) as `{:rate_limiter, node()}`, and broadcasts increments/resets to peers discovered through Horde so all nodes converge on the same counters. Non-auth pipelines (CLI auth, OAuth/OIDC, SAML, dashboard publish, plugin upload) opt in by bucket name with per-route config from `config.exs`. The existing `ServiceRadarWebNGWeb.Auth.RateLimiter` (single-node ETS, currently broken on multi-replica deployments) becomes a thin shim that delegates to the shared limiter. Buckets are deployment-wide; tenant separation is provided by the platform (per-tenant k8s namespace + CNPG schema + NATS account), not by app-layer scoping.
- **ADD** `ServiceRadarWebNGWeb.Plugs.SecurityHeaders` that issues a baseline CSP (default-src 'self', no inline scripts outside the LiveView client manifest, frame-ancestors 'none'), HSTS (when scheme is `https`), Referrer-Policy `strict-origin-when-cross-origin`, Permissions-Policy locking down camera/microphone/geolocation/payment, and `X-Permitted-Cross-Domain-Policies: none`. Wired into the `:browser` and `:api` pipelines via `endpoint.ex`.
- **ADD** `ServiceRadarWebNGWeb.Plugs.UploadGuard` with magic-number content-type detection, configurable size caps per route, filename sanitization (strip control chars, truncate to 120 chars), and randomized storage names. Applied to plugin/dashboard upload paths; controllers stop reimplementing it.
- **ADD** `ServiceRadar.Security.SecurityEvent` Ash resource (append-only, partitioned by month) and `ServiceRadar.Security.Events` recorder for the stateless event stream: failed login, rate-limit denial, policy denial, signature failure, lockout trigger. Resources that already use AshPaperTrail (credentials, ansible, console sessions) continue to do so for "who changed what record" — this resource is for "what happened" events that have no row to version. Events are deployment-wide; tenant isolation is handled by the platform.
- **ADD** brute-force lockout on top of the rate limiter: progressive backoff (1m → 5m → 30m → 24h) per IP+actor key, and an admin-unlockable account-level lockout after sustained failures across multiple IPs. Lockout state lives in `ServiceRadar.Security.AuthLockout` (Ash resource with AshPaperTrail) so unlocks are auditable.
- **ADD** operator surfaces in web-ng under a net-new **Settings → Audit** section, gated by a new `:audit_viewer` (read) and `:security_admin` (write/unlock) capability:
  - **Resource version history**: unified view across all AshPaperTrail-enabled resources (credentials, ansible playbooks/runs, console sessions, plus the new `AuthLockout`) with per-resource filters, diff view, and actor attribution. Today these versions exist in the DB but are not surfaced anywhere.
  - **Security event stream**: live + historical view of `SecurityEvent` rows with filters (kind, severity, actor, IP, route, time range) and CSV export.
  - **Lockouts**: list locked accounts, unlock action (requires `:security_admin`), shows lockout reason and history.
  - **Rate-limit inspection**: read-only view of current bucket pressure (top keys by hits, recent denials).
  Settings → Audit is a new top-level section. We considered placing it under Observability but kept Observability for runtime system signals (metrics/logs/traces) and reserved Audit for administrative who-did-what concerns.
- **MODIFY** `ServiceRadarWebNGWeb.Auth.RateLimiter` to delegate to the shared limiter and emit `SecurityEvent` rows for every denial. **BREAKING** for any test that stubs the old module directly — call sites should keep working without changes.
- **MODIFY** the `:api` and `:browser` router pipelines to add `SecurityHeaders` and (where appropriate) named rate-limit buckets.
- **MODIFY** the Phoenix session cookie configuration in `ServiceRadarWebNGWeb.Endpoint` to (a) add an `:encryption_salt` so the session payload is encrypted at rest in the cookie, not just signed; (b) set `secure: true` in production (and any deployment served over HTTPS); and (c) tighten `same_site` from `"Lax"` to `"Strict"` for the auth session cookie. **BREAKING for live sessions on deploy**: existing cookies become unreadable once encryption is enabled, so all logged-in users will be signed out once at rollout. Communicated via release notes.

## Impact

- Affected specs:
  - **NEW** capability: `platform-security`
- Affected code:
  - `elixir/web-ng/lib/serviceradar_web_ng_web/auth/rate_limiter.ex` (becomes a delegate)
  - `elixir/web-ng/lib/serviceradar_web_ng_web/endpoint.ex` (plug stack + session cookie hardening)
  - `elixir/web-ng/lib/serviceradar_web_ng_web/router.ex` (pipelines + bucket assignments)
  - `elixir/web-ng/lib/serviceradar_web_ng_web/controllers/{cli_auth,saml,oauth,oidc,auth,dashboard_package_publish}_controller.ex` (drop inline rate-limit code, use named pipeline)
  - `elixir/serviceradar_core/lib/serviceradar/security/` (new modules: `RateLimiter`, `Events`, `SecurityEvent`, `AuthLockout`)
  - `elixir/serviceradar_core/lib/serviceradar/application.ex` (supervise the new ETS owner)
  - `config/config.exs`, `config/runtime.exs` (bucket config, CSP toggles, lockout thresholds)
  - `elixir/web-ng/lib/serviceradar_web_ng_web/live/settings/audit_live/` (new Settings → Audit LiveViews for security events and lockouts)
  - `elixir/web-ng/lib/serviceradar_web_ng_web/components/navigation.ex` or equivalent (add Settings → Audit nav entry, gated by `:audit_viewer`)
  - `elixir/web-ng/test/...` + `elixir/serviceradar_core/test/...` (plug + resource tests)
- Operational impact:
  - CSP will need a short bake-in period under report-only before enforcement; design.md captures the rollout.
  - `SecurityEvent` retention defaults to 90 days (configurable); writes are append-only and indexed by `(occurred_at, kind, subject_key)`.
  - No new external dependencies. Reuses existing `ash`, `ash_paper_trail`, `plug`, and ETS.
- Backwards compatibility:
  - `ServiceRadarWebNGWeb.Auth.RateLimiter.check_rate_limit/2` and `record_attempt/2` signatures are preserved; behavior is unchanged from a caller's perspective.
  - No schema migration on existing tables; only new tables for `security_events`, `auth_lockouts`, and the `auth_lockout_versions` paper-trail table.
  - Session cookie hardening is a **one-time forced sign-out** at the deploy that enables encryption. After that, sessions are seamless. Document in the release notes and stagger the deploy outside business hours if needed.
