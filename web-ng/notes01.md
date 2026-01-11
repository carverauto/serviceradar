# Session Notes: Tenant Schema Isolation - COMPLETED

## Summary

Implemented the `Ash.Scope` pattern for passing tenant context through the application. Instead of threading `actor` and `tenant` as separate parameters through all helper functions, we now pass a `scope` struct that contains all the context Ash needs.

## Key Changes

### 1. New Protocol Implementation (`lib/serviceradar_web_ng/ash_tenant.ex`)

Implemented `Ash.Scope.ToOpts` for our `ServiceRadarWebNG.Accounts.Scope` struct:

```elixir
defimpl Ash.Scope.ToOpts, for: ServiceRadarWebNG.Accounts.Scope do
  def get_actor(%{user: user}), do: {:ok, user}
  def get_tenant(%{active_tenant: nil}), do: :error
  def get_tenant(%{active_tenant: tenant}), do: {:ok, tenant}
  def get_context(%{tenant_memberships: memberships}), do: {:ok, %{shared: %{tenant_memberships: memberships}}}
  def get_tracer(_), do: :error
  def get_authorize?(_), do: :error
end
```

Note: `Ash.ToTenant` for `ServiceRadar.Identity.Tenant` is already implemented in `serviceradar_core` (see `tenant_to_tenant.ex`).

### 2. SRQL Module Updates

Changed from `actor:` and `tenant:` to `scope:`:

```elixir
# Before
srql_module.query(query, %{actor: actor, tenant: tenant})

# After
srql_module.query(query, %{scope: scope})
```

### 3. AshAdapter Updates

Simplified the execute_query function:

```elixir
# Before
defp execute_query(_domain, query, actor, tenant) do
  opts = []
  opts = if actor, do: Keyword.put(opts, :actor, actor), else: opts
  opts = if tenant, do: Keyword.put(opts, :tenant, tenant), else: opts
  Ash.read(query, opts)
end

# After
defp execute_query(_domain, query, scope) do
  opts = if scope, do: [scope: scope], else: []
  Ash.read(query, opts)
end
```

### 4. LiveView Updates

All LiveViews now extract `current_scope` from socket assigns and pass it directly:

```elixir
# Before
actor = Map.get(socket.assigns, :actor)
tenant = Map.get(socket.assigns, :tenant)
load_data(srql_module, uid, actor, tenant)

# After
scope = Map.get(socket.assigns, :current_scope)
load_data(srql_module, uid, scope)
```

## Files Modified

1. **`lib/serviceradar_web_ng/ash_tenant.ex`** - NEW: Ash.Scope.ToOpts implementation
2. **`lib/serviceradar_web_ng/srql.ex`** - Accept `scope:` instead of `actor:`/`tenant:`
3. **`lib/serviceradar_web_ng/srql/ash_adapter.ex`** - Use `scope:` in Ash.read()
4. **`lib/serviceradar_web_ng_web/srql/page.ex`** - Pass scope through query chain
5. **`lib/serviceradar_web_ng_web/live/analytics_live/index.ex`** - Use scope
6. **`lib/serviceradar_web_ng_web/live/device_live/index.ex`** - Use scope in helpers
7. **`lib/serviceradar_web_ng_web/live/device_live/show.ex`** - Use scope in all helpers
8. **`lib/serviceradar_web_ng_web/live/log_live/index.ex`** - Use scope in helpers
9. **`lib/serviceradar_web_ng_web/stats.ex`** - Accept scope instead of actor/tenant

## How It Works

1. LiveView has `socket.assigns.current_scope` containing:
   - `user` - the current user (actor)
   - `active_tenant` - the current tenant struct
   - `tenant_memberships` - list of memberships

2. When calling SRQL:
   ```elixir
   scope = socket.assigns.current_scope
   srql_module.query(query, %{scope: scope})
   ```

3. SRQL passes scope to AshAdapter, which calls:
   ```elixir
   Ash.read(query, scope: scope)
   ```

4. Ash uses `Ash.Scope.ToOpts` protocol to extract:
   - `actor` from `scope.user`
   - `tenant` from `scope.active_tenant` (then converted via `Ash.ToTenant` to schema string)

5. `Ash.ToTenant.to_tenant(tenant, resource)` returns:
   - For `:context` strategy: `"tenant_platform"` (schema name)
   - For `:attribute` strategy: tenant ID (UUID)

## Benefits

1. **Cleaner code** - No need to thread separate actor/tenant through all helpers
2. **Single source of truth** - Scope struct contains all context
3. **Protocol-based** - Ash automatically extracts what it needs
4. **Future-proof** - Easy to add context to scope without changing function signatures
