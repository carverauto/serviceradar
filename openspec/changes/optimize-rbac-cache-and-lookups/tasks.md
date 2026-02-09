## 1. ETS-based cross-process permission cache

- [x] 1.1 Create `elixir/serviceradar_core/lib/serviceradar/identity/rbac/cache.ex` GenServer
  - Named ETS table `:rbac_permissions_cache` with `[:set, :public, :named_table, read_concurrency: true]`
  - `get(user_id)` -- returns `{:ok, MapSet.t()}` or `:miss` (checks expiry)
  - `put(user_id, permissions_mapset)` -- stores `{user_id, mapset, monotonic_expiry}`
  - `invalidate(user_id)` -- deletes entry for user
  - `invalidate_all()` -- clears entire table
  - Periodic cleanup of expired entries via `Process.send_after` (every 60s)
- [x] 1.2 Add `RBAC.Cache` to `serviceradar_core` application supervision tree (after PubSub)
- [x] 1.3 TTL defaults to 300s via `Application.get_env`, configurable in config.exs
- [x] 1.4 Update `permissions_for_user/2` to use two-tier cache:
  - L1: Process dictionary (fastest, per-process)
  - L2: ETS table (shared, with TTL)
  - L3: Database query (fallback)
  - Store result as `MapSet` at all levels

## 2. MapSet for O(1) permission lookups

- [x] 2.1 Update `permissions_for_user/2` return type from `[String.t()]` to `MapSet.t(String.t())`
- [x] 2.2 Update `has_permission?/2` to use `MapSet.member?/2`
- [x] 2.3 Update `Catalog.permissions_for_role/1` to return `MapSet.new()` instead of list
- [x] 2.4 `Scope.permissions` field now holds `MapSet.t()` or `nil` (no struct change needed, just callers)
- [x] 2.5 Update `WebRBAC.can?/2` to pattern match `%MapSet{}` and use `MapSet.member?/2`
- [x] 2.6 Update `WebRBAC.permissions_for_scope/1` to pattern match `%MapSet{}`
- [x] 2.7 `create_scope/1` in `user_auth.ex` stores MapSet (returns from `permissions_for_user`)
- [x] 2.8 Update `get_actor/1` in `ash_scope.ex` to pattern match `%MapSet{}` and pass in actor map
- [x] 2.9 Update `set_ash_actor` plug in `router.ex` to check `%MapSet{}` instead of `is_list`

## 3. Optimize ActorHasPermission policy evaluation

- [x] 3.1 Add fast path in `ActorHasPermission.match?/3`: when `actor` is a map with `:permissions` MapSet, do `MapSet.member?` directly
- [x] 3.2 Keep fallback path calling `RBAC.has_permission?/2` for actors without pre-loaded permissions

## 4. Cache invalidation via PubSub

- [x] 4.1 Added `invalidate_user_cache/1` and `invalidate_all_caches/0` to `RBAC` module
  - Broadcasts `{:rbac_cache_invalidate, user_id}` and `{:rbac_cache_invalidate_all}` on PubSub
- [x] 4.2 `RBAC.Cache` GenServer subscribes to `rbac:cache_invalidation` topic and handles messages
- [x] 4.3 `invalidate_all_caches/0` clears full table (used for RoleProfile changes)
- [x] 4.4 Wire `InvalidateUserRbacCache` change into User `update_role` and `update_role_profile` actions
- [x] 4.5 Wire `InvalidateRbacCache` change into RoleProfile `create`, `create_system`, `update`, and `destroy` actions

## 5. Build and test verification

- [x] 5.1 Verify `mix compile` succeeds for serviceradar_core (clean, no warnings)
- [x] 5.2 Verify `mix compile` succeeds for web-ng (clean, no warnings)
- [ ] 5.3 Verify existing RBAC behavior unchanged (permission checks, role-based UI rendering)
- [ ] 5.4 Verify cache invalidation works (change user role, verify new permissions take effect)
- [ ] 5.5 Verify ETS cache shared across processes (LiveView mount, API request, Oban worker)
