# ServiceRadar Core - Developer Guide

## Authorization Pattern: SystemActor

Background operations (GenServers, Oban workers, seeders) must never use `authorize?: false`.
Instead, use `ServiceRadar.Actors.SystemActor` to provide proper authorization context.

### Why Not `authorize?: false`?

Using `authorize?: false` bypasses ALL authorization policies, including tenant isolation.
This creates security vulnerabilities where background operations could inadvertently access
cross-tenant data. A Credo check will flag any usage of `authorize?: false` in the codebase.

### Usage Patterns

#### Tenant-Scoped Operations

For operations within a single tenant's context:

```elixir
alias ServiceRadar.Actors.SystemActor

# Create actor for the tenant
actor = SystemActor.for_tenant(tenant_id, :my_component_name)

# Use with Ash operations
Resource
|> Ash.Query.for_read(:list)
|> Ash.read!(actor: actor, tenant: tenant_schema)

Resource
|> Ash.Changeset.for_create(:create, attrs)
|> Ash.create!(actor: actor, tenant: tenant_schema)
```

#### Platform-Wide Operations

For operations that span tenants or manage platform resources (bootstrap, seeding, tenant management):

```elixir
alias ServiceRadar.Actors.SystemActor

# Create platform actor
actor = SystemActor.platform(:tenant_bootstrap)

# Use with Ash operations (no tenant context needed)
Tenant
|> Ash.Query.for_read(:list)
|> Ash.read!(actor: actor)
```

### Component Naming

Use descriptive component names that identify the calling system:

- `:state_monitor` - StateMonitor GenServer
- `:health_tracker` - HealthTracker GenServer
- `:sweep_compiler` - Sweep compilation operations
- `:tenant_bootstrap` - Tenant creation/bootstrap
- `:template_seeder` - Template seeding operations

### Authorization Policies

Resources use the following bypass pattern for system actors:

```elixir
# Schema-isolated resources (most resources)
bypass always() do
  authorize_if actor_attribute_equals(:role, :system)
end

# Public schema resources with global?: true (e.g., TenantMembership)
bypass always() do
  authorize_if expr(^actor(:role) == :system and tenant_id == ^actor(:tenant_id))
end
```

Schema-isolated resources rely on PostgreSQL schema boundaries for tenant isolation,
so they only need to check the `:system` role. Resources in the public schema with
`global?: true` must also verify the tenant_id matches.

## Multi-Tenancy Model

ServiceRadar uses PostgreSQL schema-based multi-tenancy:

- Each tenant has its own schema (e.g., `tenant_abc123`)
- Most resources use `multitenancy strategy: :context` (schema-isolated)
- Some resources use `multitenancy strategy: :attribute` with `global?: true` (public schema)

### Public Schema Resources

These live in the public schema and require explicit tenant_id checks in policies:

- `tenants` - Tenant records
- `tenant_memberships` - User-tenant associations
- `nats_platform_tokens` - Platform NATS tokens
- `nats_operators` - NATS operator configuration

### Tenant Schema Resources

All other resources are isolated by PostgreSQL schema boundaries.
