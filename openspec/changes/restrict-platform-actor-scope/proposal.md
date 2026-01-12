# Proposal: Restrict Platform Actor Scope

## Problem Statement

The current `SystemActor.platform/1` function creates actors with a `:super_admin` role that can bypass tenant isolation. This is dangerous because:

1. **Overly broad permissions**: `super_admin` implies god-mode access across all tenants
2. **Abuse potential**: Any code using platform actors could accidentally or maliciously access/modify tenant data
3. **Unclear boundaries**: No clear definition of what platform operations are actually legitimate
4. **Tenant deletion risk**: Platform actors could delete tenants, bypassing proper closure workflows

## Current State

```elixir
def platform(component) when is_atom(component) do
  %{
    id: "platform:#{component}",
    email: "#{component_to_email(component)}@platform.serviceradar",
    role: :super_admin  # <-- Too powerful
  }
end
```

This role is used for:
- Listing all tenants (seeders, bootstrap)
- Looking up tenants by slug (authentication flows)
- Creating NATS operators (infrastructure bootstrap)
- Querying cross-tenant resources during startup

## Proposed Solution

### 1. Replace `:super_admin` with scoped roles

Instead of a single `super_admin` role, define specific platform roles:

- `:platform_reader` - Can read tenant metadata (slug, id, status) but not tenant data
- `:platform_bootstrap` - Can create initial infrastructure (operators, platform tenant)
- `:platform_seeder` - Can seed default data into tenant schemas

### 2. Remove tenant deletion from platform actors

Tenant closure should be:
- **Self-service**: Tenant admin initiates closure
- **Billing-triggered**: Non-payment triggers suspension then closure
- **Audited**: All closure actions require explicit user action with audit trail

Platform actors should NEVER be able to delete or deactivate tenants.

### 3. Constrain cross-tenant queries

Platform actors should only be able to:
- List tenant IDs/slugs (for routing)
- Check tenant status (active/suspended)
- Read platform-level configuration

They should NOT be able to:
- Read tenant-internal data (devices, alerts, users)
- Modify tenant data
- Delete or suspend tenants
- Access tenant secrets/credentials

### 4. Explicit action allowlists

Each resource should explicitly declare which actions platform roles can perform:

```elixir
policies do
  policy action(:read) do
    authorize_if actor_attribute_equals(:role, :platform_reader)
    # Only allows reading tenant metadata, not internal data
  end
end
```

## Security Boundaries

| Operation | Allowed Actor | Notes |
|-----------|--------------|-------|
| List all tenants (metadata only) | `:platform_reader` | For routing, seeding |
| Create platform tenant | `:platform_bootstrap` | One-time bootstrap only |
| Create NATS operator | `:platform_bootstrap` | One-time bootstrap only |
| Seed tenant defaults | `:platform_seeder` | Creates default rules/templates |
| Delete/suspend tenant | **NONE** | Must be self-service or billing |
| Read tenant data | Tenant actors only | Never platform actors |
| Modify tenant data | Tenant actors only | Never platform actors |

## Migration Path

1. Update `SystemActor.platform/1` to accept a scope parameter
2. Add new platform roles to authorization policies
3. Audit all current platform actor usages
4. Restrict each usage to minimum required scope
5. Add policy tests to verify boundaries

## Success Criteria

- No platform actor can access tenant-internal data
- No platform actor can delete/modify tenants
- All cross-tenant operations are explicitly scoped
- Policy tests verify boundaries are enforced
