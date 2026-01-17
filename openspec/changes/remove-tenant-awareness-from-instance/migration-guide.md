# Migration Guide: Tenant-Unaware Instance

This guide explains how to update code for the final tenant-unaware model. Isolation
is enforced by PostgreSQL search_path; no tenant context is passed in
application code.

## Overview

- Remove all `tenant:` parameters from Ash operations.
- Remove `TenantSchemas` usage and any cross-tenant iteration.
- Use `SystemActor.system/1` for background operations.
- Control Plane owns account provisioning and cross-account operations.

## Pattern 1: Tenant-Scoped Ash Operations

### Before (tenant-aware)

```elixir
actor = SystemActor.for_tenant(tenant.id, :collector_controller)
packages = Ash.read!(query, actor: actor, tenant: tenant)
```

### After (tenant-unaware)

```elixir
actor = SystemActor.system(:collector_controller)
packages = Ash.read!(query, actor: actor)
```

## Pattern 2: Cross-Tenant Operations

### Before (cross-schema lookup)

```elixir
defp find_package_across_tenants(package_id) do
  TenantSchemas.list_schemas()
  |> Enum.reduce_while({:error, :not_found}, fn schema, _ ->
    # Search each schema
  end)
end
```

### After (remove entirely)

Delete cross-schema helpers. Instances operate only on their own schema.
Cross-account operations live in the Control Plane.

## Pattern 3: AshAuthentication JWT Verification

AshAuthentication may still use internal tenant handling for token verification.
This is the only acceptable `tenant:` usage; do not add any new tenant-aware
code paths.
