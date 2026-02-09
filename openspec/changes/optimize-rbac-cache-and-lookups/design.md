## Context

After fixing the RBAC N+1 query problem (fix-rbac-performance-bottleneck), the system is faster but still has architectural inefficiencies in how permissions are cached and checked. The process dictionary cache solved the per-request problem but doesn't help across processes, and list-based permission lookups remain O(n).

**Current architecture:**
- `permissions_for_user/2` uses `Process.get/put` -- cache is per-process, no TTL, no sharing
- Permissions stored as `[String.t()]` -- `in` operator is O(n) linear scan
- ~30-40 permissions per role, 2-6 `ActorHasPermission` checks per resource action
- 43 policy check sites across 13 Ash resources
- `effective_profile/2` does an Ash query to `RoleProfile` (indexed, but still a DB round-trip)
- `Catalog.permissions_for_role/1` recomputes dynamically via `Enum.flat_map/filter/map` each call

**Stakeholders:** web-ng LiveView processes, API controllers, Oban workers, any GenServer making authorized Ash calls.

## Goals / Non-Goals

**Goals:**
- Eliminate redundant DB queries for the same user's permissions across all processes
- Reduce permission membership checks from O(n) to O(1)
- Reduce `ActorHasPermission` overhead by short-circuiting when permissions are pre-loaded
- Provide cache invalidation when roles/profiles change
- Keep backward compatibility -- code that passes a `%User{}` without pre-loaded permissions still works

**Non-Goals:**
- Removing the Permit library (separate evaluation, task 4.1)
- Adding telemetry/metrics instrumentation (Phase 3 of prior proposal)
- Changing the RBAC catalog structure or permission key format
- Changing Ash policy DSL or authorization patterns

## Decisions

### Decision 1: ETS table over :persistent_term or GenServer state

**Choice:** Named ETS table owned by a GenServer (`RBAC.Cache`), using `:read_concurrency` optimization.

**Alternatives considered:**
- `:persistent_term` -- Excellent read performance but expensive writes (global GC on update). Permission changes are infrequent but not rare enough to justify persistent_term's write cost.
- GenServer state with `call/cast` -- Serializes all reads through a single process. ETS allows concurrent reads from any process without bottleneck.
- Redis/external cache -- Overkill for single-node deployment model. Adds external dependency.

**Rationale:** ETS with `:read_concurrency` gives near-zero overhead reads from any process and cheap writes. The GenServer only manages table ownership and TTL cleanup.

### Decision 2: MapSet over list for permissions

**Choice:** Store permissions as `MapSet.t()` everywhere (ETS cache, Scope struct, Ash actor map).

**Alternatives considered:**
- Sorted list with binary search -- Still O(log n), more complex, no stdlib support
- Map with `true` values -- Semantically odd, MapSet is the idiomatic Erlang/Elixir approach
- Bitfield/integer flags -- Would require permission-to-bit mapping, fragile across catalog changes

**Rationale:** `MapSet.member?/2` is O(1) for small-to-medium sets (implemented as a map internally). Drop-in replacement with minimal code changes. Guards like `is_list(permissions)` become `is_struct(permissions, MapSet)` or we use a protocol/function.

### Decision 3: TTL-based expiry with event-driven invalidation

**Choice:** 5-minute default TTL + immediate invalidation via PubSub on role/profile changes.

**Rationale:** TTL provides a safety net for stale data. PubSub broadcast on `RoleProfile` create/update/destroy and `User` role change ensures near-instant propagation. Both mechanisms together mean: fast invalidation in the common case, guaranteed freshness within TTL in edge cases.

### Decision 4: ActorHasPermission reads from actor map directly

**Choice:** When `actor` is a map with `:permissions` key containing a `MapSet`, `ActorHasPermission.match?/3` does `MapSet.member?(actor.permissions, permission)` directly, bypassing the full `RBAC.has_permission?` call chain.

**Rationale:** The actor map is already enriched at authentication time (from `ash_scope.ex`). This avoids the function call chain `match? -> has_permission? -> permissions_for_user -> Process.get/ETS lookup` and replaces it with a single `MapSet.member?` call.

## Risks / Trade-offs

- **Stale permissions within TTL window** -- A user whose role changes may retain old permissions for up to 5 minutes if PubSub invalidation fails. Mitigation: PubSub invalidation is the primary mechanism; TTL is the fallback.
- **ETS memory usage** -- One entry per active user. Each entry is `{user_id, MapSet, expiry}`. With ~100 concurrent users and ~40 permissions each, memory is negligible (~50KB total).
- **MapSet serialization** -- MapSet doesn't JSON-serialize cleanly. Only matters if permissions are sent over the wire (they aren't -- they stay in BEAM memory).
- **Backward compatibility** -- Code checking `is_list(permissions)` will need updating. Mitigated by doing this in a single pass across known call sites.

## Migration Plan

1. Add `RBAC.Cache` GenServer with ETS table to `serviceradar_core` application supervision tree
2. Update `permissions_for_user/2` to check ETS first, fall back to DB, store as MapSet
3. Keep `Process.get/put` as L1 cache in front of ETS (process-local is still fastest)
4. Update `has_permission?/2` to use `MapSet.member?/2`
5. Update `Scope.permissions` to hold MapSet; update `can?` and `permissions_for_scope`
6. Update `ActorHasPermission.match?/3` to read from actor map directly
7. Add PubSub invalidation on RoleProfile and User role changes
8. Update all `is_list(permissions)` guards to handle MapSet

## Open Questions

- Should TTL be configurable at runtime (env var) or compile-time (config.exs)? Leaning toward config.exs with runtime override.
- Should we add a `:telemetry` event for cache hit/miss now or defer to Phase 3? Leaning toward adding the event now since we're touching the cache code anyway.
