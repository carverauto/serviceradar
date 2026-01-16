# ServiceRadar Core - Developer Guide

## Authorization Pattern: SystemActor

Background operations (GenServers, Oban workers, seeders) must never use `authorize?: false`.
Instead, use `ServiceRadar.Actors.SystemActor` to provide proper authorization context.

### Why Not `authorize?: false`?

Using `authorize?: false` bypasses ALL authorization policies.
A Credo check will flag any usage of `authorize?: false` in the codebase.

### Usage Patterns

#### Instance-Scoped Operations

For operations within the tenant instance (DB search_path determines the schema):

```elixir
alias ServiceRadar.Actors.SystemActor

# Create system actor
actor = SystemActor.system(:my_component_name)

# Use with Ash operations
Resource
|> Ash.Query.for_read(:list)
|> Ash.read!(actor: actor)

Resource
|> Ash.Changeset.for_create(:create, attrs)
|> Ash.create!(actor: actor)
```

#### Platform-Wide Operations

For operations that manage platform resources (bootstrap, seeding, tenant management):

```elixir
alias ServiceRadar.Actors.SystemActor

# Create platform actor
actor = SystemActor.platform(:tenant_bootstrap)

# Use with Ash operations
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
# DB connection's search_path determines the schema
bypass always() do
  authorize_if actor_attribute_equals(:role, :system)
end
```

## Instance Isolation Model

Each tenant deployment is fully isolated:

- Each tenant gets their own deployment (agent-gateway, web-ng, core-elx)
- CNPG credentials set PostgreSQL's `search_path` for schema isolation
- DB connection's search_path determines the schema
- No cross-tenant access is possible at the instance level

### Schema-Isolated Resources

All resources use `multitenancy strategy: :context` and are isolated by PostgreSQL schema boundaries set via the database connection's search_path.
