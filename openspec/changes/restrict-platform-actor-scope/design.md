# Design: Restricted Platform Actor Scope

## Architectural Context

ServiceRadar is a multi-tenant SaaS platform where tenant isolation is a critical security boundary. The `authorize?: false` security debt fix introduced `SystemActor` to provide proper actors for background operations, but the `platform/1` variant uses a `:super_admin` role that is too permissive.

## Current Problem

```
┌─────────────────────────────────────────────────────────────┐
│                    Platform Actor Today                      │
├─────────────────────────────────────────────────────────────┤
│  SystemActor.platform(:component)                           │
│                    │                                         │
│                    ▼                                         │
│         role: :super_admin                                   │
│                    │                                         │
│    ┌───────────────┼───────────────┐                        │
│    ▼               ▼               ▼                        │
│ Tenant A       Tenant B       Tenant C                      │
│ (full access)  (full access)  (full access)  ← DANGEROUS    │
└─────────────────────────────────────────────────────────────┘
```

The `:super_admin` role can potentially:
- Read any tenant's data
- Modify any tenant's configuration
- Delete tenants
- Access secrets and credentials

## Proposed Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                 Scoped Platform Actors                       │
├─────────────────────────────────────────────────────────────┤
│  SystemActor.platform(:bootstrap)                           │
│         │                                                    │
│         ▼ role: :platform_bootstrap                         │
│    ┌────────────────┐                                       │
│    │ NatsOperator   │  (create only, one-time)              │
│    │ Platform Tenant│  (create only, one-time)              │
│    └────────────────┘                                       │
├─────────────────────────────────────────────────────────────┤
│  SystemActor.platform(:reader)                              │
│         │                                                    │
│         ▼ role: :platform_reader                            │
│    ┌────────────────┐                                       │
│    │ Tenant.slug    │  (read-only metadata)                 │
│    │ Tenant.id      │                                       │
│    │ Tenant.status  │                                       │
│    └────────────────┘                                       │
│         ✗ Cannot read tenant data                           │
│         ✗ Cannot modify tenants                             │
│         ✗ Cannot delete tenants                             │
├─────────────────────────────────────────────────────────────┤
│  SystemActor.platform(:seeder)                              │
│         │                                                    │
│         ▼ role: :platform_seeder                            │
│    ┌────────────────┐                                       │
│    │ ZenRule        │  (create defaults in tenant schema)   │
│    │ Templates      │                                       │
│    └────────────────┘                                       │
│         ✗ Cannot read/modify existing tenant data           │
└─────────────────────────────────────────────────────────────┘
```

## Role Definitions

### `:platform_reader`
**Purpose**: Allow routing and tenant discovery without access to tenant data.

**Allowed**:
- Read tenant `id`, `slug`, `status`, `is_platform_tenant`
- Query tenants by slug for authentication routing

**Denied**:
- Read tenant internal data (users, devices, alerts, etc.)
- Read tenant secrets (NATS credentials, CA keys, etc.)
- Modify any tenant attributes
- Delete or suspend tenants

### `:platform_bootstrap`
**Purpose**: One-time infrastructure initialization.

**Allowed**:
- Create platform tenant (if not exists)
- Create NATS operator (if not exists)
- Initialize platform infrastructure

**Denied**:
- Everything else
- Should ideally be time-limited or require explicit enable flag

### `:platform_seeder`
**Purpose**: Seed default data into tenant schemas.

**Allowed**:
- Create default rules/templates in tenant schemas
- Read existing rules/templates to avoid duplicates

**Denied**:
- Modify existing tenant-created data
- Delete tenant data
- Access tenant secrets

## Implementation Strategy

### Phase 1: Add Scoped Roles (Non-Breaking)
```elixir
def platform(scope) when scope in [:reader, :bootstrap, :seeder] do
  %{
    id: "platform:#{scope}",
    email: "platform-#{scope}@system.serviceradar",
    role: scope_to_role(scope)
  }
end

defp scope_to_role(:reader), do: :platform_reader
defp scope_to_role(:bootstrap), do: :platform_bootstrap
defp scope_to_role(:seeder), do: :platform_seeder
```

### Phase 2: Update Policies
```elixir
# In Tenant resource
policies do
  policy action(:read) do
    # Platform reader can only see metadata
    authorize_if expr(
      actor(:role) == :platform_reader and
      selecting_only?([:id, :slug, :status, :is_platform_tenant])
    )
  end

  # No policy allows platform roles to delete
  policy action(:destroy) do
    forbid_if actor_attribute_equals(:role, :platform_reader)
    forbid_if actor_attribute_equals(:role, :platform_bootstrap)
    forbid_if actor_attribute_equals(:role, :platform_seeder)
  end
end
```

### Phase 3: Migrate Callers
Update all `SystemActor.platform(:component_name)` calls to use specific scopes:

| Current Usage | New Scope |
|--------------|-----------|
| `platform_tenant_bootstrap.ex` | `:bootstrap` |
| `operator_bootstrap.ex` | `:bootstrap` |
| `template_seeder.ex` | `:seeder` |
| `zen_rule_seeder.ex` | `:seeder` |
| `rule_seeder.ex` | `:seeder` |
| `tenant_resolver.ex` | `:reader` |
| `create_account_worker.ex` | `:reader` |

## Tenant Closure Design

Instead of allowing platform actors to delete tenants, implement a proper closure workflow:

```
┌─────────────────────────────────────────────────────────────┐
│                  Tenant Closure Flow                         │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│  User Initiated          Billing Triggered                  │
│       │                        │                            │
│       ▼                        ▼                            │
│  ┌─────────────┐        ┌─────────────┐                    │
│  │ Close       │        │ Payment     │                    │
│  │ Account     │        │ Failed      │                    │
│  │ Button      │        │ Webhook     │                    │
│  └──────┬──────┘        └──────┬──────┘                    │
│         │                      │                            │
│         ▼                      ▼                            │
│  ┌─────────────────────────────────────┐                   │
│  │    status: :pending_closure          │                   │
│  │    closure_reason: :user_requested   │                   │
│  │                   :payment_failed    │                   │
│  │    closure_requested_at: DateTime    │                   │
│  └──────────────┬──────────────────────┘                   │
│                 │                                           │
│                 ▼ (30 day grace period)                    │
│  ┌─────────────────────────────────────┐                   │
│  │    status: :suspended               │                   │
│  │    suspended_at: DateTime            │                   │
│  └──────────────┬──────────────────────┘                   │
│                 │                                           │
│                 ▼ (90 day retention)                       │
│  ┌─────────────────────────────────────┐                   │
│  │    Oban Worker: ArchiveTenantData   │                   │
│  │    - Export data to cold storage    │                   │
│  │    - Drop tenant schema             │                   │
│  │    - Mark tenant as :closed         │                   │
│  └─────────────────────────────────────┘                   │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

## Security Considerations

1. **No backdoors**: Platform actors should never bypass the closure workflow
2. **Audit everything**: All platform actor operations must be logged
3. **Principle of least privilege**: Each scope should have minimum required access
4. **Defense in depth**: Policies + code checks + audit logs
5. **Fail closed**: If scope is unclear, deny access

## Trade-offs

| Approach | Pros | Cons |
|----------|------|------|
| Scoped roles | Fine-grained control, auditable | More complexity, more policies |
| Single super_admin | Simple | Security risk, abuse potential |
| No platform actors | Maximum isolation | Can't do cross-tenant operations |

The scoped roles approach provides the best balance of security and functionality.
