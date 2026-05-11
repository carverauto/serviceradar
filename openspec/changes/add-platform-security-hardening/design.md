## Context

ServiceRadar's web tier is a Phoenix LiveView app (`elixir/web-ng`) backed by Ash resources in `elixir/serviceradar_core`. Auth supports local + OIDC + SAML + CLI device flows; ingest paths include Falco webhooks and dashboard package publish. Today, security defenses are split across:

- A small `ServiceRadarWebNGWeb.Auth.RateLimiter` GenServer (ETS table `:auth_rate_limiter`, 5 attempts / 60s) used by ~6 auth-adjacent controllers and LiveViews.
- Phoenix defaults: `protect_from_forgery`, `put_secure_browser_headers`, signed-and-encrypted sessions with `SameSite=Lax`.
- AshPaperTrail on credentials, ansible, and console session resources (versioning, not security event capture).
- Ad-hoc HMAC verification inside Falco controllers.
- Per-controller upload size limits and content-type checks.

The sibling project `inkit` recently consolidated equivalent concerns into ~4 reusable plugs + an ETS rate limiter. We want to bring that consolidation to ServiceRadar without inheriting `inkit`'s single-tenant assumptions, and without duplicating what AshPaperTrail already gives us.

## Goals / Non-Goals

**Goals**
- Single shared rate-limiter implementation with named buckets; pipelines opt in by name.
- Defense-in-depth response headers (CSP, HSTS, Referrer-Policy, Permissions-Policy) applied centrally.
- Reusable upload guard + webhook signature plug; controllers stop reimplementing.
- Queryable security event stream for stateless events (failed login, denial, signature failure, lockout).
- Progressive backoff + account lockout on top of the rate limiter.
- Operator UI to inspect events and unlock accounts.

**Non-Goals**
- Replacing AshPaperTrail. Resource version history continues to live there.
- WAF-class protections (SQLi, XSS scanning of request bodies) — out of scope; assume Phoenix's encoder + Ash's parameterized queries.
- DDoS protection at the edge. Rate limits are app-tier; volumetric DDoS is a deployment concern.
- App-layer multi-tenant scoping. ServiceRadar isolates tenants at the platform layer (per-tenant k8s namespace + CNPG schema + NATS account); each deployment is effectively single-tenant from the app's perspective, so rate-limit buckets, audit logs, and webhook secrets are deployment-wide.
- Replacing existing auth flows. We extend, not rewrite.

## Decisions

### D1. Rate-limiter substrate: ETS GenServer (not `hammer`/`plug_attack`)

Keep the ETS+GenServer pattern already in use. The existing limiter handles ~production traffic, and `hammer` would introduce a runtime dependency for marginal benefit. Move the implementation into `ServiceRadar.Security.RateLimiter` (core app) so non-web callers (NATS ingest, etc) can use the same buckets if needed later.

Bucket keys: `{bucket_name, subject_key}` where `subject_key` is typically the client IP, but auth-related buckets can use `{ip, actor_id}` to prevent password spraying. ETS table is a `:set` with `read_concurrency: true, write_concurrency: true`, owned by a supervised GenServer that handles sweeping. Buckets are deployment-wide — tenancy in ServiceRadar is infrastructure-level (per-tenant k8s namespace + CNPG schema + NATS account), so app-layer per-tenant scoping is unnecessary.

**Alternatives considered**: `hammer` (extra dep, less control), Redis-backed limiter (extra infra, network hop per request). Rejected — ETS is sufficient for current scale (one app node typical; multi-node uses sticky-IP load balancing already).

### D2. Plug stack ordering

Order in `:browser` and `:api` pipelines:

```
plug :accepts
plug :fetch_session                       # browser only
plug :protect_from_forgery                # browser only
plug ServiceRadarWebNGWeb.Plugs.SecurityHeaders
plug ServiceRadarWebNGWeb.Plugs.RateLimit, bucket: :api_default
# route-specific plugs follow (UploadGuard, WebhookSignature)
```

`SecurityHeaders` must run before any response is written; `RateLimit` runs before expensive controllers but after session/CSRF so we can attribute hits to authenticated actors.

### D3. CSP rollout: report-only → enforced

CSP breaks easily. Phase rollout:

1. Ship `SecurityHeaders` with `content-security-policy-report-only` only, pointing at `/api/security/csp-report`.
2. Observe reports for 1 week (operator dashboard surface).
3. Flip a runtime config to enforce.

CSP body (initial):
```
default-src 'self';
script-src 'self' 'wasm-unsafe-eval';
style-src 'self' 'unsafe-inline';   # LiveView injects inline styles
img-src 'self' data: blob:;
font-src 'self' data:;
connect-src 'self' wss: https:;
frame-ancestors 'none';
base-uri 'self';
form-action 'self';
report-uri /api/security/csp-report;
```

`'unsafe-inline'` on `style-src` is a known LiveView constraint; tracked as an open question.

### D4. Audit story: AshPaperTrail + SecurityEvent

Two stores, different shapes:

- **AshPaperTrail** (already deployed): row-level version history for mutable resources. Keep using and extend the existing `PaperTrailMixin` pattern when adding new sensitive resources (e.g., `AuthLockout`, `WebhookSecret`).
- **SecurityEvent** (new): append-only event log for things that don't map to a row mutation: `:login_failed`, `:rate_limit_denied`, `:policy_denied`, `:signature_invalid`, `:lockout_triggered`, `:lockout_cleared`, `:csp_violation`. Each row carries `occurred_at`, `kind`, `severity`, `actor_id` (nullable), `ip`, `route`, `details` (jsonb), `correlation_id`. Indexed by `(occurred_at desc)` and `(kind, occurred_at desc)`. Retention: 90d default, configurable, enforced by a daily Oban job (or scheduled task — see open questions).

The recorder (`ServiceRadar.Security.Events.record/1`) is a fire-and-forget cast that fans out to a queue-backed writer to avoid taking the hot path latency hit. On overflow, events are dropped with a counter increment rather than blocking the request.

### D5. Lockout model

Two layers:

- **Per-IP progressive backoff** (handled inside `RateLimiter`): on each denial, escalate the bucket's window. Backoff schedule: `[1m, 5m, 30m, 24h]`. Cleared by 1h of inactivity.
- **Per-actor lockout** (new `AuthLockout` resource): when an actor accumulates ≥ N (configurable, default 20) failed logins across any IPs within a 1h window, lock the account. Lockout is a row with `actor_id`, `locked_at`, `locked_by` (`:system` or admin user_id), `expires_at` (nullable for permanent), `reason`. Unlock is an Ash action requiring `:security_admin` capability; emits a SecurityEvent.

Lockouts are checked at the start of any auth attempt; locked accounts get a generic "account temporarily locked" message (no info leak about lockout reason).

### D6. Webhook secret storage

`WebhookSecret` is an Ash resource keyed by `source_name` (e.g., `falco`, `partner_x`). Secret stored as `encrypted_value` using the existing `ServiceRadar.Vault` cloak. Rotation: create a new secret with `superseded_by_id` chain so verification can accept both old + new during a grace window (default 5 min). AshPaperTrail enabled so rotations are auditable.

### D7. Audit surface lives under Settings → Audit (new top-level section)

AshPaperTrail versions and the new `SecurityEvent` rows are written today but not displayed anywhere. We add a new **Settings → Audit** section rather than placing this under Observability, because:

- Observability is reserved for runtime system signals (OTel metrics/logs/traces, alert rules, signal coverage). Mixing administrative who-did-what data there blurs the boundary and complicates RBAC.
- Audit data is administrative — it answers "who changed this credential" and "who got denied at the door" — and naturally pairs with the other Settings panels operators already use for credentials, plugins, and agents.

The surface has four sub-pages:

1. **History** — unified AshPaperTrail version timeline across enabled resources, with resource-type, actor, action, and time-range filters. Each row deep-links to a diff view that renders the change set.
2. **Events** — `SecurityEvent` stream with the same filter set plus kind/severity. Supports CSV export. Live tail via Phoenix.PubSub for the most recent 100 events.
3. **Lockouts** — current and recent `AuthLockout` rows; unlock action available to `:security_admin`.
4. **Webhook Secrets** — per-source secret list with last-used timestamp and a rotate action that establishes a grace window.

Optionally, a **Rate Limits** read-only panel surfaces top buckets by hits and recent denials. Live-updates via PubSub.

Two capabilities gate the section:

- `:audit_viewer` — read-only access to all sub-pages.
- `:security_admin` — required for unlock, secret rotation, and any state-changing action. A subset of `:audit_viewer`.

Both capabilities are added to the RBAC catalog and the existing settings policy modules. Default role mappings: `:owner` and `:admin` get `:security_admin`; `:operator` gets `:audit_viewer`.

### D8. Upload guard

`UploadGuard` is a plug, not a controller helper, so it runs before the body is fully consumed by the controller. It uses Plug's `:parsers` upload mechanism (`Plug.Upload`) — checks happen post-parse but pre-controller. Magic-number detection covers the formats we actually accept today (PNG/JPEG for assets, application/zip / application/wasm for plugins). Filename sanitization replaces sequences matching `[\x00-\x1F\x7F]` with `_` and truncates to 120 chars; storage filename is `{millis}-{16-byte-base64-random}{ext}`.

Per-route config supplied via plug opts: `bucket`, `max_bytes`, `allowed_mime`, `require_magic_match: true`.

## Risks / Trade-offs

| Risk | Mitigation |
|---|---|
| CSP breaks LiveView assets or third-party embeds | Ship report-only first; collect reports for ≥7 days before enforcing; document escape hatch (per-route `disable_csp`). |
| ETS limiter becomes hot under spray | Single-table `:set` with `write_concurrency: true`; if contention shows, shard by `:erlang.phash2(key, N)` across N tables. |
| SecurityEvent write rate during attack overwhelms DB | Bounded queue with drop counter; sample CSP reports (1-in-100) under load. |
| False positives on `WebhookSignature` during rotation | Two-key acceptance window during rotation; grace period configurable. |
| Generic auth rate limit blocks legitimate burst (e.g., CI device-flow) | Bucket config per route, with explicit higher limits for CI device flow. Document defaults in `config/config.exs`. |
| Lockout creates support burden | Operator UI surfaces unlock; lockouts auto-expire after `expires_at`; emit metric/alert when lockout count crosses threshold. |
| Multi-node deployments diverge on rate-limit state | Out of scope for v1; document as known limitation. Most deployments are single-node web tier; multi-node uses sticky-IP load balancing. SaaS rollout will run one web pod per tenant namespace, which sidesteps this for the SaaS path. |

## Migration Plan

1. Land `RateLimiter` core module + supervisor entry; existing auth limiter starts delegating. No behavior change.
2. Land `SecurityHeaders` in report-only CSP mode. Observe.
3. Land `UploadGuard` and migrate plugin-publish + dashboard-publish to use it; remove inline checks.
4. Land `WebhookSignature` and migrate Falco controllers; rotate secrets through the new `WebhookSecret` resource.
5. Land `SecurityEvent` resource + recorder; emit from the limiter, plugs, and Ash policy denials.
6. Land `AuthLockout` resource + progressive backoff; rolling deploy.
7. Operator UI under Settings → Audit (History, Events, Lockouts, Webhook Secrets, Rate Limits).
8. Flip CSP to enforce after report bake-in.

Rollback: each step is independently revertible. CSP can be set to report-only via runtime config without redeploy.

## Open Questions

1. Should `SecurityEvent` retention be driven by an Oban job (consistent with existing retention jobs) or a dedicated GenServer? Leaning Oban for consistency.
2. CSP `style-src 'unsafe-inline'` for LiveView — is there a current path to nonce-based styles in the version we're on? If yes, prefer nonce.
3. CSP `connect-src` for the LiveView WebSocket — should we enumerate explicit hosts, or accept `wss:` broadly?
4. Should `WebhookSignature` support signature schemes beyond HMAC-SHA256 (e.g., Ed25519 for inbound from partner systems)? Defer until needed.
5. Account-level lockout for CLI device-flow actors vs interactive users — should we treat them as a single actor or split keys? Leaning split.
