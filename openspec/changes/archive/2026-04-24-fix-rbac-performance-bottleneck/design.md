## Context

The web-ng Elixir Phoenix LiveView app uses a dual-layer RBAC system:

1. **Ash policies** (`ActorHasPermission` checks on 90+ resources) — enforces authorization at the domain/data layer
2. **Permit** (by Curiosum) — enforces authorization at the UI/controller layer for admin settings routes only

Both systems ultimately call `ServiceRadar.Identity.RBAC.permissions_for_user/2`, which reads a `RoleProfile` from the database via Ash. On staging, this function has no caching, causing N+1 queries proportional to the number of `can?` template checks and Ash policy evaluations per request.

### Stakeholders
- All web-ng users (every authenticated page is affected)
- Admin users (additionally affected by Permit hook overhead)

## Goals / Non-Goals

### Goals
- Reduce RoleProfile DB queries from ~25/page to 1/session-mount
- Fix the broken build (remove non-existent `ash_opentelemetry` dependency)
- Revert unrelated CSP regression
- Add observability to measure RBAC overhead in production (Phase 2)
- Maintain all existing RBAC behavior (no functional changes)

### Non-Goals
- Removing or replacing Permit (it works fine for its limited scope; only 4 routes)
- Replacing Ash policies with a different authorization system
- Adding cross-process shared caching (ETS) — evaluate in Phase 4 if needed
- Changing the permission model or catalog structure

## Decisions

### Decision 1: Process-level cache in `permissions_for_user/2`

**What:** Use `Process.put/get` to cache permissions per user ID within a process.

**Why:** In Phoenix/LiveView, each request or LiveView connection runs in its own process. Process dictionary caching ensures:
- 1 DB query on first call per process
- All subsequent `can?` and `ActorHasPermission` checks are free (O(n) list membership, no DB)
- No stale-cache invalidation complexity (process ends → cache gone)
- No shared mutable state between processes

**Alternatives considered:**
- **ETS table with TTL**: More complex, requires cache invalidation when RoleProfile changes. Overkill for current scale. Can add later in Phase 4.
- **Cachex/ConCache**: External dependency for a simple use case. Process dictionary is simpler.
- **GenServer cache**: Adds a SPOF and serialization bottleneck. Not worth it.

### Decision 2: Pre-load permissions in Scope struct

**What:** Call `permissions_for_user` once during `create_scope/1` (in UserAuth) and store the result in `%Scope{permissions: [...]}`.

**Why:** The Scope flows through the entire request lifecycle:
- Conn assigns → plugs → controllers
- Socket assigns → LiveView mount → all handle_* callbacks → template renders

By loading permissions once at scope creation time, all downstream consumers can access them without any function call overhead.

### Decision 3: Enriched actor in `AshScope.get_actor/1`

**What:** When the Scope has pre-loaded permissions, return a map actor with `permissions: [...]` key instead of the raw User struct.

**Why:** The `permissions_for_user/2` function has a clause that matches `%{permissions: permissions}` maps and returns the list directly — no DB query, no process cache lookup. This ensures Ash policy evaluations (`ActorHasPermission`) for LiveView operations via `scope:` option are zero-cost.

### Decision 4: Optimize `WebRBAC.can?/2` to use scope permissions

**What:** Check `scope.permissions` directly instead of calling `RBAC.has_permission?(scope.user, perm)`.

**Why:** Currently `can?/2` passes the User struct, which hits the process cache (fast) but still does an O(n) list membership check through function calls. Using `scope.permissions` directly avoids the function call chain entirely and makes the check transparent — the permissions are right there in the scope.

### Decision 5: Separate OTEL into Phase 2

**What:** Remove all OpenTelemetry changes from the RBAC fix PR. Add them in a separate PR.

**Why:**
- The OTEL changes have a broken dependency (`ash_opentelemetry` doesn't exist)
- Mixing correctness fixes with new feature additions makes the PR hard to review
- OTEL can be validated independently once the app is running fast again
- The correct dependency (`opentelemetry_ash` ~> 0.1.3) and config (`OpentelemetryAsh`) need separate testing

## Risks / Trade-offs

### Risk: Stale permissions after RoleProfile change
- **Impact:** If an admin changes a user's RoleProfile, the affected user won't see the change until they reconnect (LiveView) or make a new request (HTTP).
- **Mitigation:** This is acceptable for RBAC changes which are infrequent. For LiveView, the existing `Endpoint.broadcast("disconnect")` pattern on user changes forces reconnection. Can add explicit cache invalidation in Phase 4 if needed.

### Risk: Process dictionary is invisible to debugging tools
- **Mitigation:** Add `:telemetry.execute` events for cache hit/miss in Phase 3. Process dictionary is standard Erlang/OTP — used by Logger, Ecto sandbox, etc.

### Trade-off: O(n) list membership vs MapSet
- Current: `permission in permissions` is O(n) where n = number of permissions per user (~20-50 typically)
- Alternative: Pre-compute `MapSet.new(permissions)` for O(1) lookup
- **Decision:** Keep list for now. At n=50, the difference is negligible. Can optimize in Phase 4 if profiling shows it matters.

## Migration Plan

### Phase 1 (This PR)
1. Apply the working changes from the prior branch (cache, scope enrichment, ash_scope, router)
2. Fix `WebRBAC.can?/2` to use scope permissions
3. Remove all OTEL-related changes
4. Verify build passes
5. Test all authenticated pages load quickly
6. Rollback: revert this PR (no schema changes, no migrations)

### Phase 2 (Separate PR)
1. Add correct OTEL dependencies (`opentelemetry_ash` ~> 0.1.3)
2. Configure `OpentelemetryAsh` tracer
3. Configure exporter to `serviceradar-otel:4317`
4. Add slow query logging (100ms threshold)
5. Deploy and verify traces appear in OTEL collector

## Open Questions

- Should we add a `clear_process_cache` call when handling the `Endpoint.broadcast("disconnect")` event to ensure users get fresh permissions on reconnect? (Likely unnecessary since the process dies on disconnect anyway.)
- Is the Permit AuthorizeHook on settings routes adding measurable overhead beyond the RBAC caching fix? (Measure in Phase 3 with OTEL traces.)
- Should we expose a cache-busting mechanism for admin "apply RBAC changes now" workflows? (Phase 4 consideration.)
