# Change: Fix RBAC Performance Bottleneck Causing Slow Page Loads

## Why

Every page load in the web-ng Phoenix LiveView app triggers **N+1 database queries** to the `role_profiles` table. On staging, `permissions_for_user/2` has **zero caching** — each call to `RBAC.can?/2` in templates (14-23 calls per page) and each `ActorHasPermission` Ash policy check triggers a fresh `RoleProfile` Ash read. A single settings page render can execute **25+ identical DB roundtrips** for the same user's role profile. This is the primary cause of the reported "unbearably slow" page loads.

A prior agent attempted to fix this (commits `a89f8a2ba`, `39d42d9d8`) but introduced a non-existent dependency (`ash_opentelemetry`), incorrect OpenTelemetry configuration, unrelated CSP regressions, and the build is broken. This proposal supersedes OpenSpec 004 with a corrected, phased approach.

## Root Cause Analysis

### The N+1 Pattern (Staging Behavior)

```
Request arrives
  → fetch_current_scope_for_user plug: Scope.for_user(user) [no permissions loaded]
  → set_ash_actor plug: permissions_for_user(user)        → DB QUERY #1 (RoleProfile)
  → Template render:
      RBAC.can?(scope, "devices.view")                    → DB QUERY #2
      RBAC.can?(scope, "devices.create")                  → DB QUERY #3
      RBAC.can?(scope, "devices.import")                  → DB QUERY #4
      ... (14-23 more can? calls per page)                → DB QUERY #5-25
  → Any Ash operation with ActorHasPermission policy:
      (actor is enriched map with permissions from plug)   → No DB query (clause 2 match)

LiveView mount (different process, no plug pipeline):
  → mount_current_scope: Scope.for_user(user) [no permissions loaded]
  → RBAC.can? in template: permissions_for_user(user)     → DB QUERY #1
  → RBAC.can? in template: permissions_for_user(user)     → DB QUERY #2
  → ... (14-23 more)                                      → DB QUERY #3-25
  → Ash operations via scope protocol:
      get_actor returns raw User struct
      ActorHasPermission calls permissions_for_user(user)  → DB QUERY #26+
```

### Why Permit Is Not The Core Problem

Permit (`Permit.Phoenix.LiveView.AuthorizeHook`) is only used on 4 routes (`/settings/authentication`, `/settings/auth/users`, `/settings/auth/users/:id`, `/settings/auth/rbac`). It maps only 2 permission strings (`settings.auth.manage`, `settings.rbac.manage`). The global slowdown is from the uncached `permissions_for_user` calls that happen on **every** page, not just Permit-protected ones.

### What The Prior Branch Got Right

1. Process-level caching in `permissions_for_user` (prevents repeated DB hits within same process)
2. Pre-loading permissions in `create_scope` (loads once during auth, stores in Scope)
3. Enriched actor in `AshScope.get_actor` (Ash policy checks use pre-loaded permissions)
4. Conditional permission reuse in `set_ash_actor` plug (avoids redundant DB query)

### What The Prior Branch Got Wrong

1. **`ash_opentelemetry` does not exist** — correct package is `opentelemetry_ash` (~> 0.1.3)
2. **Wrong tracer module** — `Ash.Tracer.OpenTelemetry` should be `OpentelemetryAsh`
3. **Wrong `OpentelemetryEcto.setup` call** — passes incorrect arguments
4. **No `WebRBAC.can?` optimization** — still passes User struct through RBAC.has_permission? instead of using pre-loaded scope permissions

## What Changes

### Phase 1: Fix Build + RBAC Caching (Critical — fixes the N+1)
- Keep process-level cache in `permissions_for_user/2` (good fix from prior branch)
- Keep permissions pre-loading in `create_scope/1` and Scope struct (good fix)
- Keep enriched actor in `AshScope.get_actor/1` (good fix)
- Keep conditional reuse in `set_ash_actor` plug (good fix)
- **Fix `WebRBAC.can?/2`** to use `scope.permissions` directly when available (avoids User struct path entirely)
- **Remove all OpenTelemetry changes** from this phase (move to Phase 2)

### Phase 2: OpenTelemetry Observability (Separate PR)
- Add `opentelemetry_ash` (~> 0.1.3) — the **correct** package name
- Add `opentelemetry_phoenix`, `opentelemetry_live_view`, `opentelemetry_ecto`, `opentelemetry_cowboy`
- Configure tracer as `OpentelemetryAsh` (not `Ash.Tracer.OpenTelemetry`)
- Configure exporter to `serviceradar-otel:4317`
- Add slow query logging to Ecto (100ms threshold)

### Phase 3: RBAC Telemetry + Monitoring
- Add `:telemetry.execute` around `permissions_for_user` to track cache hit/miss rates
- Add RBAC-specific dashboard metrics to LiveDashboard
- Monitor RoleProfile query frequency in production OTEL traces

### Phase 4: Architecture Optimization (Future)
- Evaluate replacing remaining Permit usage with pure RBAC.can? checks (only 2 permissions mapped)
- Consider ETS-based cross-process permission cache with TTL for high-traffic deployments
- Consider precomputing `MapSet` for O(1) permission lookups instead of O(n) list membership

## Impact
- Affected specs: `rbac-route-protection`, `ash-authorization`
- Affected code:
  - `elixir/serviceradar_core/lib/serviceradar/identity/rbac.ex` (process cache)
  - `web-ng/lib/serviceradar_web_ng_web/user_auth.ex` (scope enrichment)
  - `web-ng/lib/serviceradar_web_ng/accounts/scope.ex` (permissions field)
  - `web-ng/lib/serviceradar_web_ng/ash_scope.ex` (enriched actor)
  - `web-ng/lib/serviceradar_web_ng/rbac.ex` (scope-aware can?)
  - `web-ng/lib/serviceradar_web_ng_web/router.ex` (set_ash_actor optimization)
  - `web-ng/mix.exs` and `elixir/serviceradar_core/mix.exs` (Phase 2: OTEL deps)
  - `web-ng/config/config.exs` (Phase 2: OTEL config)
- **BREAKING**: None. All changes are internal optimization; external behavior unchanged.
- **Expected improvement**: ~25x reduction in RoleProfile DB queries per page load (from 25+ to 1)
