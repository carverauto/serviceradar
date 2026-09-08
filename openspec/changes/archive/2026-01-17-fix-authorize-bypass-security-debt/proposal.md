# Proposal: Fix authorize?: false Security Debt

## Summary

Replace all instances of `authorize?: false` in the codebase with proper system actors that maintain tenant isolation. Currently, ~115 instances bypass Ash authorization entirely, creating potential security vulnerabilities where tenant isolation policies are not enforced for background operations.

## Problem Statement

The codebase contains widespread use of `authorize?: false` in Ash operations:

```elixir
# CURRENT (INSECURE) - bypasses ALL authorization including tenant isolation
|> Ash.read(authorize?: false, tenant: tenant_schema)
|> Ash.update(authorize?: false, tenant: tenant_schema)
```

This pattern:
1. **Bypasses tenant isolation** - Policies checking `actor(:tenant_id)` are skipped
2. **No audit trail** - System operations have no identifiable actor
3. **Security debt** - Any new authorization policies are automatically bypassed
4. **CVE risk** - Multi-tenant data leakage if tenant isolation policies are the only defense

## Proposed Solution

Implement a `SystemActor` module providing tenant-scoped system actors for all background operations:

```elixir
# NEW (SECURE) - uses system actor with tenant_id for policy enforcement
actor = ServiceRadar.Actors.SystemActor.for_tenant(tenant_id, :state_monitor)
|> Ash.read(actor: actor, tenant: tenant_schema)
|> Ash.update(actor: actor, tenant: tenant_schema)
```

### SystemActor Module

Create `ServiceRadar.Actors.SystemActor` that generates actors with:
- `tenant_id` - For tenant isolation policy enforcement
- `role: :system` - Distinguished from user roles
- `id` - Unique identifier for the system component
- `email` - Descriptive identifier for audit logs (e.g., `state-monitor@system.serviceradar`)

### Migration Strategy

1. **Phase 1**: Create SystemActor module and add `:system` role to authorization policies
2. **Phase 2**: Fix high-risk files (GenServers, workers with tenant data access)
3. **Phase 3**: Fix medium-risk files (seeders, bootstrap code)
4. **Phase 4**: Fix remaining files and add lint rule to prevent regression

## Scope

### In Scope
- All ~115 instances of `authorize?: false` in `lib/serviceradar/`
- New `ServiceRadar.Actors.SystemActor` module
- Updates to ash-authorization policies to recognize `:system` role
- Credo custom check to prevent new `authorize?: false` usage

### Out of Scope
- Test files (test helpers may legitimately use `authorize?: false`)
- Changes to Ash framework itself

## Success Criteria

1. Zero instances of `authorize?: false` in production code (excluding tests)
2. All background operations use SystemActor with proper tenant_id
3. Tenant isolation policies enforced for all Ash operations
4. Credo check prevents regression

## Risk Assessment

- **Low**: Existing policies may need adjustment to allow `:system` role
- **Medium**: Some operations may fail if policies are too restrictive
- **Mitigation**: Implement in phases with thorough testing per file

## References

- `openspec/specs/ash-authorization/spec.md` - Existing authorization requirements
- `openspec/specs/tenant-isolation/spec.md` - Tenant isolation requirements
- `lib/serviceradar/agent_config/compilers/sweep_compiler.ex:129` - Example of correct `build_system_actor` pattern
