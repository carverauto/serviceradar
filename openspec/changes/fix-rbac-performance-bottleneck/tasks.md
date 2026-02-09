## 1. Phase 1: Fix Build and RBAC Caching

### 1.1 Revert broken changes from prior branch
- [x] 1.1.1 Remove `ash_opentelemetry` from `elixir/serviceradar_core/mix.exs`
- [x] 1.1.2 Remove `ash_opentelemetry` from `web-ng/mix.exs`
- [x] 1.1.3 Remove all OTEL dependencies from both mix.exs files (opentelemetry, opentelemetry_api, opentelemetry_exporter, opentelemetry_ecto, opentelemetry_phoenix, opentelemetry_live_view, opentelemetry_cowboy)
- [x] 1.1.4 Remove `OpentelemetryEcto.setup` call from `elixir/serviceradar_core/lib/serviceradar/application.ex`
- [x] 1.1.5 Remove `OpentelemetryPhoenix.setup` and `OpentelemetryLiveView.setup` from `web-ng/lib/serviceradar_web_ng/application.ex`
- [x] 1.1.6 Remove OTEL config block from `web-ng/config/config.exs` (opentelemetry resource, processors, ash tracer)

### 1.2 Keep and validate RBAC caching fixes
- [x] 1.2.1 Verify process-level cache in `permissions_for_user/2` (`elixir/serviceradar_core/lib/serviceradar/identity/rbac.ex`) — keep Process.get/put pattern and `clear_process_cache/0`
- [x] 1.2.2 Verify `permissions` field added to Scope struct (`web-ng/lib/serviceradar_web_ng/accounts/scope.ex`) — keep `defstruct user: nil, permissions: nil`
- [x] 1.2.3 Verify `create_scope/1` in UserAuth pre-loads permissions (`web-ng/lib/serviceradar_web_ng_web/user_auth.ex`) — keep `permissions = RBAC.permissions_for_user(user)` + `Scope.for_user(user, permissions: permissions)`
- [x] 1.2.4 Verify enriched actor in AshScope (`web-ng/lib/serviceradar_web_ng/ash_scope.ex`) — keep the new `get_actor` clause that returns map with permissions
- [x] 1.2.5 Verify conditional permission reuse in `set_ash_actor` plug (`web-ng/lib/serviceradar_web_ng_web/router.ex`) — keep the `is_list(scope_permissions)` check

### 1.3 Optimize WebRBAC.can?
- [x] 1.3.1 Update `WebRBAC.can?/2` in `web-ng/lib/serviceradar_web_ng/rbac.ex` to check `scope.permissions` directly when available, falling back to `RBAC.has_permission?` for backward compatibility
- [x] 1.3.2 Update `WebRBAC.permissions_for_scope/1` to return `scope.permissions` when available

### 1.4 Async LiveView data loading
- [x] 1.4.1 Defer `LogLive.Index` handle_params data loading to handle_info via `:load_tab_data`
- [x] 1.4.2 Add `tab_loading` assign with loading spinner to observability page
- [x] 1.4.3 Defer `NetflowLive.Visualize` handle_params data loading to handle_info via `:load_viz_data`
- [x] 1.4.4 Add `viz_loading` assign with loading spinner to netflow visualize page

### 1.5 Build verification
- [x] 1.5.1 Verify `mix compile` succeeds for web-ng (clean, no warnings)
- [x] 1.5.2 Verify `mix compile` succeeds for serviceradar_core (clean)
- [ ] 1.5.3 Verify Bazel build succeeds (if accessible)

### 1.6 Functional verification
- [ ] 1.6.1 Verify authenticated page loads (analytics, devices, settings)
- [ ] 1.6.2 Verify RBAC.can? checks render correct UI elements based on user role
- [ ] 1.6.3 Verify Ash operations work with enriched actor (create, read, update, delete)
- [ ] 1.6.4 Verify Permit-protected settings pages still enforce authorization

## 2. Phase 2: OpenTelemetry Observability (Separate PR)

- [ ] 2.1 Add correct OTEL dependencies to both mix.exs:
  - `opentelemetry` ~> 1.3
  - `opentelemetry_api` ~> 1.2
  - `opentelemetry_exporter` ~> 1.6
  - `opentelemetry_ecto` ~> 1.1
  - `opentelemetry_phoenix` ~> 1.1
  - `opentelemetry_live_view` ~> 1.0.0-rc.4
  - `opentelemetry_cowboy` ~> 0.2
  - `opentelemetry_ash` ~> 0.1.3 (NOT `ash_opentelemetry`)
- [ ] 2.2 Configure Ash tracer as `OpentelemetryAsh` (NOT `Ash.Tracer.OpenTelemetry`)
- [ ] 2.3 Configure OTEL exporter to `serviceradar-otel:4317` via gRPC
- [ ] 2.4 Initialize instrumentation in Application.start callbacks
- [ ] 2.5 Add slow query logging to Ecto config (100ms threshold in prod.exs)
- [ ] 2.6 Verify traces appear in OTEL collector

## 3. Phase 3: RBAC Telemetry (Future)

- [ ] 3.1 Add `:telemetry.execute` events for permissions_for_user cache hit/miss
- [ ] 3.2 Add RBAC metrics to LiveDashboard
- [ ] 3.3 Monitor RoleProfile query frequency in OTEL traces

## 4. Phase 4: Architecture Optimization (Future)

- [ ] 4.1 Evaluate removing Permit for settings routes (only 2 permissions mapped)
- [ ] 4.2 Consider ETS-based cross-process cache with TTL
- [ ] 4.3 Consider MapSet for O(1) permission lookups
- [ ] 4.4 Profile and optimize ActorHasPermission policy evaluation overhead
