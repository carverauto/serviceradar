# Change: Optimize RBAC permission cache and policy lookups

## Why

The current RBAC permission system has three architectural bottlenecks:

1. **Process-local cache with no TTL or cross-process sharing** -- Each Erlang process (LiveView, API controller, Oban worker) independently fetches permissions from the database via `effective_profile`. There is no shared cache, so the same user's permissions are re-queried for every new process. Process dictionary caching only helps within a single request/connection.

2. **O(n) list membership checks** -- Permissions are stored as a plain `[String.t()]` list. Every `has_permission?` / `can?` call does `permission in permissions` which is a linear scan. With ~30-40 permissions per role and 2-6 `ActorHasPermission` policy checks per Ash resource action, this adds up to 60-240 list iterations per request.

3. **Repeated `ActorHasPermission` evaluation overhead** -- 43 policy check sites across 13 Ash resources each call `RBAC.has_permission?/2`, which in turn calls `permissions_for_user/2`. While the process cache avoids repeated DB queries within a process, the list scan and function call overhead remains on every check.

## What Changes

- **ETS-based cross-process permission cache with TTL** -- Replace the `Process.get/put` cache with a shared ETS table (`ServiceRadar.Identity.RBAC.Cache`). Keyed by `user_id`, values are `{MapSet.t(), expiry_monotonic}`. All processes in the VM share the same cached permissions. TTL defaults to 5 minutes, configurable. Explicit invalidation on role/profile changes via PubSub broadcast.
- **MapSet for O(1) permission lookups** -- Store permissions as `MapSet` in the ETS cache and in `Scope.permissions`. Change `has_permission?` and `can?` to use `MapSet.member?/2` instead of `in` on a list.
- **Reduce ActorHasPermission call overhead** -- When the Ash actor map already contains a `:permissions` MapSet (enriched at authentication time), `ActorHasPermission.match?/3` reads it directly without calling back into `RBAC.has_permission?/2`.

## Impact

- Affected specs: `rbac-route-protection` (adds caching and lookup requirements)
- Affected code:
  - `elixir/serviceradar_core/lib/serviceradar/identity/rbac.ex` -- cache layer
  - `elixir/serviceradar_core/lib/serviceradar/identity/rbac/cache.ex` -- new GenServer
  - `elixir/serviceradar_core/lib/serviceradar/policies/checks.ex` -- ActorHasPermission fast path
  - `web-ng/lib/serviceradar_web_ng/rbac.ex` -- MapSet-aware `can?`
  - `web-ng/lib/serviceradar_web_ng/accounts/scope.ex` -- permissions type
  - `web-ng/lib/serviceradar_web_ng_web/user_auth.ex` -- store MapSet in scope
  - `web-ng/lib/serviceradar_web_ng/ash_scope.ex` -- pass MapSet to actor
- GitHub issue: #2747
