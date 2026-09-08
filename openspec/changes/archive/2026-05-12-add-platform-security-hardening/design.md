## Context

ServiceRadar's web tier is a Phoenix LiveView app (`elixir/web-ng`) backed by Ash resources in `elixir/serviceradar_core`. Auth supports local + OIDC + SAML + CLI device flows; ingest paths include the dashboard package publish endpoint. Today, security defenses are split across:

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
- Reusable upload guard; controllers stop reimplementing.
- Queryable security event stream for stateless events (failed login, denial, signature failure, lockout).
- Progressive backoff + account lockout on top of the rate limiter.
- Operator UI to inspect events and unlock accounts.

**Non-Goals**
- Replacing AshPaperTrail. Resource version history continues to live there.
- WAF-class protections (SQLi, XSS scanning of request bodies) — out of scope; assume Phoenix's encoder + Ash's parameterized queries.
- DDoS protection at the edge. Rate limits are app-tier; volumetric DDoS is a deployment concern.
- App-layer multi-tenant scoping. ServiceRadar isolates tenants at the platform layer (per-tenant k8s namespace + CNPG schema + NATS account); each deployment is effectively single-tenant from the app's perspective, so rate-limit buckets and audit logs are deployment-wide.
- Replacing existing auth flows. We extend, not rewrite.

## Decisions

### D1. Rate-limiter substrate: cluster-aware ETS via `ServiceRadar.ProcessRegistry` (Horde)

Keep the ETS+GenServer pattern already in use, and make it correct for multi-replica deployments — which is the norm, not the exception. The current `ServiceRadarWebNGWeb.Auth.RateLimiter` uses single-node ETS with no broadcasting, so on the 3-replica demo a client effectively gets 3× the documented allowance by hitting different pods. Fixing this is part of the proposal, not a future concern.

Approach: every node keeps its own local ETS table for fast reads. The owning GenServer registers itself in the existing Horde-backed `ServiceRadar.ProcessRegistry` (see `elixir/serviceradar_core/lib/serviceradar/registry/process_registry.ex`) under the key `{:rate_limiter, node()}` on init. Writes (increments and resets) look up the cluster-wide set of registered rate-limiter PIDs via `ProcessRegistry.select_by_type(:rate_limiter)`, exclude self, and broadcast a cast to each peer so all nodes converge on the same counters. ServiceRadar already runs libcluster + Horde across web-ng replicas (see `elixir/web-ng/config/runtime.exs:631` for the libcluster topologies and `elixir/serviceradar_core/lib/serviceradar/registry/process_registry.ex` for the Horde registries), so we are not introducing a new clustering mechanism — we are using the established pattern that already powers gateway / agent process discovery.

Bucket keys: `{bucket_name, subject_key}` where `subject_key` is typically the client IP, but auth-related buckets can use `{ip, actor_id}` to prevent password spraying. ETS table is a `:set` with `read_concurrency: true, write_concurrency: true`. Buckets are deployment-wide — tenancy in ServiceRadar is infrastructure-level (per-tenant k8s namespace + CNPG schema + NATS account), so app-layer per-tenant scoping is unnecessary.

Consistency model: eventually consistent. A burst that races the broadcast window can slip at most `N - 1` extra requests through, where `N` is the cluster size. For rate-limit and lockout purposes this is acceptable — the worst-case allowance with 3 replicas and a 5/min limit is 7/min, not 15/min like the current broken state. If stronger consistency is ever needed for a specific bucket, that bucket can route through a Horde-registered singleton GenServer (the cluster already supports this pattern) at the cost of an extra hop.

**Alternatives considered**:
- `hammer` (extra dep, less control)
- Mnesia with `ram_copies` across nodes (works, but heavier and slower than ETS + Horde-discovered casts; we use Mnesia nowhere else)
- `:pg` directly (works but redundant — `ServiceRadar.ProcessRegistry` already gives us cluster-wide PID discovery; matching the codebase pattern is preferable to introducing a parallel mechanism)
- Horde-supervised singleton owner (single point of contention; fine as an escape hatch for strict-consistency buckets but overkill as the default)
- Redis-backed limiter (net-new infra dependency; rejected — BEAM clustering already gives us what we need)

### D2. Plug stack ordering

Order in `:browser` and `:api` pipelines:

```
plug :accepts
plug :fetch_session                       # browser only
plug :protect_from_forgery                # browser only
plug ServiceRadarWebNGWeb.Plugs.SecurityHeaders
plug ServiceRadarWebNGWeb.Plugs.RateLimit, bucket: :api_default
# route-specific plugs follow (UploadGuard)
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

- **AshPaperTrail** (already deployed): row-level version history for mutable resources. Keep using and extend the existing `PaperTrailMixin` pattern when adding new sensitive resources (e.g., `AuthLockout`).
- **SecurityEvent** (new): append-only event log for things that don't map to a row mutation: `:login_failed`, `:rate_limit_denied`, `:policy_denied`, `:signature_invalid`, `:lockout_triggered`, `:lockout_cleared`, `:csp_violation`. Each row carries `occurred_at`, `kind`, `severity`, `actor_id` (nullable), `ip`, `route`, `details` (jsonb), `correlation_id`. Indexed by `(occurred_at desc)` and `(kind, occurred_at desc)`. Retention: 90d default, configurable, enforced by a daily Oban job (or scheduled task — see open questions).

The recorder (`ServiceRadar.Security.Events.record/1`) is a fire-and-forget cast that fans out to a per-node, queue-backed writer to avoid taking the hot path latency hit. On overflow, events are dropped with a counter increment rather than blocking the request. Per-node queues are acceptable here because the durable store is shared (CNPG), so no cross-node coordination is required for write durability — events written from any pod end up in the same `security_events` table.

### D5. Lockout model

Two layers:

- **Per-IP progressive backoff** (handled inside `RateLimiter`): on each denial, escalate the bucket's window. Backoff schedule: `[1m, 5m, 30m, 24h]`. Cleared by 1h of inactivity.
- **Per-actor lockout** (new `AuthLockout` resource): when an actor accumulates ≥ N (configurable, default 20) failed logins across any IPs within a 1h window, lock the account. Lockout is a row with `actor_id`, `locked_at`, `locked_by` (`:system` or admin user_id), `expires_at` (nullable for permanent), `reason`. Unlock is an Ash action requiring `:security_admin` capability; emits a SecurityEvent.

Lockouts are checked at the start of any auth attempt; locked accounts get a generic "account temporarily locked" message (no info leak about lockout reason).

### D6. Audit surface lives under Settings → Audit (new top-level section)

AshPaperTrail versions and the new `SecurityEvent` rows are written today but not displayed anywhere. We add a new **Settings → Audit** section rather than placing this under Observability, because:

- Observability is reserved for runtime system signals (OTel metrics/logs/traces, alert rules, signal coverage). Mixing administrative who-did-what data there blurs the boundary and complicates RBAC.
- Audit data is administrative — it answers "who changed this credential" and "who got denied at the door" — and naturally pairs with the other Settings panels operators already use for credentials, plugins, and agents.

The surface has three sub-pages:

1. **History** — unified AshPaperTrail version timeline across enabled resources, with resource-type, actor, action, and time-range filters. Each row deep-links to a diff view that renders the change set.
2. **Events** — `SecurityEvent` stream with the same filter set plus kind/severity. Supports CSV export. Live tail via Phoenix.PubSub for the most recent 100 events; PubSub runs over the BEAM cluster (`Phoenix.PubSub.PG2`) so an event recorded on any pod is broadcast to LiveView subscribers on any other pod without an extra round-trip.
3. **Lockouts** — current and recent `AuthLockout` rows; unlock action available to `:security_admin`.

Optionally, a **Rate Limits** read-only panel surfaces top buckets by hits and recent denials. Live-updates via PubSub.

Two capabilities gate the section:

- `:audit_viewer` — read-only access to all sub-pages.
- `:security_admin` — required for unlock and any state-changing action. A subset of `:audit_viewer`.

Both capabilities are added to the RBAC catalog and the existing settings policy modules. Default role mappings: `:owner` and `:admin` get `:security_admin`; `:operator` gets `:audit_viewer`.

### D7. Upload guard

`UploadGuard` is a plug, not a controller helper, so it runs before the body is fully consumed by the controller. It uses Plug's `:parsers` upload mechanism (`Plug.Upload`) — checks happen post-parse but pre-controller. Magic-number detection covers the formats we actually accept today (PNG/JPEG for assets, application/zip / application/wasm for plugins). Filename sanitization replaces sequences matching `[\x00-\x1F\x7F]` with `_` and truncates to 120 chars; storage filename is `{millis}-{16-byte-base64-random}{ext}`.

Per-route config supplied via plug opts: `bucket`, `max_bytes`, `allowed_mime`, `require_magic_match: true`.

## Risks / Trade-offs

| Risk | Mitigation |
|---|---|
| CSP breaks LiveView assets or third-party embeds | Ship report-only first; collect reports for ≥7 days before enforcing; document escape hatch (per-route `disable_csp`). |
| ETS limiter becomes hot under spray | Single-table `:set` with `write_concurrency: true`; if contention shows, shard by `:erlang.phash2(key, N)` across N tables. Writes are fanned to peers via Horde-discovered GenServer casts — the broadcast cost is `O(cluster_size)` per increment, acceptable at the cluster sizes we run. |
| SecurityEvent write rate during attack overwhelms DB | Bounded per-node queue with drop counter; sample CSP reports (1-in-100) under load. Postgres is the durable store and is shared across the cluster, so per-node queues do not affect consistency. |
| Generic auth rate limit blocks legitimate burst (e.g., CI device-flow) | Bucket config per route, with explicit higher limits for CI device flow. Document defaults in `config/config.exs`. |
| Lockout creates support burden | Operator UI surfaces unlock; lockouts auto-expire after `expires_at`; emit metric/alert when lockout count crosses threshold. |
| Cluster-wide rate-limit convergence under partition / netsplit | Buckets are local-first ETS with Horde-discovered cast fan-out; during a netsplit each partition continues to enforce locally and reconciles when the cluster reforms (last-writer-wins on counters is the BEAM cluster norm and is acceptable here). For lockouts and other state where stronger consistency is desired, the resource is persisted in CNPG via Ash so the durable record survives the partition. |

## Migration Plan

1. Land `RateLimiter` core module + supervisor entry; existing auth limiter starts delegating. No behavior change.
2. Land `SecurityHeaders` in report-only CSP mode. Observe.
3. Land `UploadGuard` and migrate plugin-publish + dashboard-publish to use it; remove inline checks.
5. Land `SecurityEvent` resource + recorder; emit from the limiter, plugs, and Ash policy denials.
6. Land `AuthLockout` resource + progressive backoff; rolling deploy.
7. Operator UI under Settings → Audit (History, Events, Lockouts, optional Rate Limits panel).
8. Flip CSP to enforce after report bake-in.

Rollback: each step is independently revertible. CSP can be set to report-only via runtime config without redeploy.

## Open Questions

1. Should `SecurityEvent` retention be driven by an Oban job (consistent with existing retention jobs) or a dedicated GenServer? Leaning Oban for consistency.
2. CSP `style-src 'unsafe-inline'` for LiveView — is there a current path to nonce-based styles in the version we're on? If yes, prefer nonce.
3. CSP `connect-src` for the LiveView WebSocket — should we enumerate explicit hosts, or accept `wss:` broadly?
5. Account-level lockout for CLI device-flow actors vs interactive users — should we treat them as a single actor or split keys? Leaning split.
