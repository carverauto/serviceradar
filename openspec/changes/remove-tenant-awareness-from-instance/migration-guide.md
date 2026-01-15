# Migration Guide: Tenant-Unaware Mode

This guide explains how to update code to support both tenant-aware and tenant-unaware modes using the `TenantMode` module.

## Overview

The `TenantMode` module provides helpers to conditionally include or exclude tenant context in Ash operations:

```elixir
alias ServiceRadar.Cluster.TenantMode

# Check mode
TenantMode.tenant_aware?()  # => true or false

# Get tenant options
TenantMode.tenant_opts(schema)  # => [tenant: schema] or []

# Get system actor (handles both modes)
TenantMode.system_actor(:component, tenant_id)

# Get full Ash options
TenantMode.ash_opts(:component, tenant_id, schema)
```

## Pattern 1: Tenant-Scoped Ash Operations

### Before (tenant-aware only)

```elixir
actor = SystemActor.for_tenant(tenant.id, :collector_controller)
packages = Ash.read!(query, actor: actor, tenant: tenant)
```

### After (supports both modes)

```elixir
alias ServiceRadar.Cluster.TenantMode
alias ServiceRadar.Cluster.TenantSchemas

schema = TenantSchemas.schema_for_tenant(tenant)
opts = TenantMode.ash_opts(:collector_controller, tenant.id, schema)
packages = Ash.read!(query, opts)
```

Or using the individual helpers:

```elixir
actor = TenantMode.system_actor(:collector_controller, tenant.id)
opts = [actor: actor] ++ TenantMode.tenant_opts(schema)
packages = Ash.read!(query, opts)
```

## Pattern 2: Cross-Tenant Operations (Platform Only)

Cross-tenant operations like `find_package_across_tenants/1` only make sense in tenant-aware mode.

### Before

```elixir
defp find_package_across_tenants(package_id) do
  actor = SystemActor.platform(:collector_controller)

  TenantSchemas.list_schemas()
  |> Enum.reduce_while({:error, :not_found}, fn schema, _ ->
    # Search each schema
  end)
end
```

### After (with mode check)

```elixir
defp find_package_across_tenants(package_id) do
  if TenantMode.tenant_aware?() do
    # Cross-tenant search (Control Plane only)
    actor = SystemActor.platform(:collector_controller)

    TenantSchemas.list_schemas()
    |> Enum.reduce_while({:error, :not_found}, fn schema, _ ->
      # Search each schema
    end)
  else
    # Tenant-unaware mode: search current schema only
    actor = SystemActor.system(:collector_controller)

    case CollectorPackage
         |> Ash.Query.for_read(:read)
         |> Ash.Query.filter(id == ^package_id)
         |> Ash.read_one(actor: actor) do
      {:ok, nil} -> {:error, :not_found}
      {:ok, package} -> {:ok, package, nil}  # No schema in tenant-unaware mode
      {:error, error} -> {:error, error}
    end
  end
end
```

## Pattern 3: Passing Tenant to Ash Changeset Operations

### Before

```elixir
case CollectorPackage
     |> Ash.Changeset.for_create(:create, attrs)
     |> Ash.Changeset.force_change_attribute(:tenant_id, tenant.id)
     |> Ash.create(actor: actor, tenant: tenant) do
```

### After

```elixir
schema = TenantSchemas.schema_for_tenant(tenant)
opts = TenantMode.ash_opts(:collector_controller, tenant.id, schema)

case CollectorPackage
     |> Ash.Changeset.for_create(:create, attrs)
     |> Ash.Changeset.force_change_attribute(:tenant_id, tenant.id)
     |> Ash.create(opts) do
```

## Files to Update

Based on grep analysis, these files contain `tenant:` parameter usage:

### Controllers (web-ng)
- `lib/serviceradar_web_ng_web/controllers/api/collector_controller.ex` (10 occurrences)
- `lib/serviceradar_web_ng_web/controllers/api/edge_controller.ex` (10 occurrences)
- `lib/serviceradar_web_ng_web/controllers/api/enroll_controller.ex` (2 occurrences)
- `lib/serviceradar_web_ng_web/controllers/tenant_controller.ex` (2 occurrences)

### LiveViews (web-ng)
- `lib/serviceradar_web_ng_web/live/admin/edge_package_live/index.ex` (12 occurrences)
- `lib/serviceradar_web_ng_web/live/admin/integration_live/index.ex` (6 occurrences)
- `lib/serviceradar_web_ng_web/live/admin/job_live/index.ex` (5 occurrences)
- ... and 20+ more LiveViews

### Auth/Plugs (web-ng)
- `lib/serviceradar_web_ng_web/plugs/api_auth.ex` (4 occurrences)
- `lib/serviceradar_web_ng/accounts/scope.ex` (10 occurrences)
- `lib/serviceradar_web_ng_web/user_auth.ex` (3 occurrences)

### Core modules
- Multiple files in `serviceradar_core` library

## Testing Strategy

1. **Unit tests**: Set `TENANT_AWARE_MODE=false` in test config
2. **Verify queries work**: Ensure operations don't fail without tenant parameter
3. **Verify isolation**: Test that DB `search_path` limits access correctly

## Rollout Strategy

1. Deploy with `TENANT_AWARE_MODE=true` (default, no behavior change)
2. Test tenant instances with `TENANT_AWARE_MODE=false` in staging
3. Roll out to production tenant instances with scoped CNPG credentials
4. Control Plane continues to use `TENANT_AWARE_MODE=true`
